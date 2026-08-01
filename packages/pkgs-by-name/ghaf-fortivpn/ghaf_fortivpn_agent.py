#!/usr/bin/env python3
# ruff: noqa: E402, F722, F821
# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

import asyncio
import sys
import threading

import gi

gi.require_version("Adw", "1")
gi.require_version("Gtk", "4.0")

from dbus_next import BusType, DBusError, Message, MessageType, Variant
from dbus_next.aio import MessageBus
from dbus_next.service import ServiceInterface, method
from gi.repository import Adw, Gio, GLib, Gtk


APPLICATION_ID = "org.ghaf.FortiVpn.SecretAgent"
NM_BUS_NAME = "org.freedesktop.NetworkManager"
NM_AGENT_MANAGER_PATH = "/org/freedesktop/NetworkManager/AgentManager"
NM_AGENT_MANAGER_INTERFACE = "org.freedesktop.NetworkManager.AgentManager"
NM_AGENT_PATH = "/org/freedesktop/NetworkManager/SecretAgent"
NM_AGENT_INTERFACE = "org.freedesktop.NetworkManager.SecretAgent"
FORTISSLVPN_SERVICE_TYPE = "org.freedesktop.NetworkManager.fortisslvpn"
PROFILE_MARKER = "org.ghaf.fortivpn"

ALLOW_INTERACTION = 0x1
REQUEST_NEW = 0x2
USER_REQUESTED = 0x4

NO_SECRETS = "org.freedesktop.NetworkManager.SecretAgent.NoSecrets"
USER_CANCELED = "org.freedesktop.NetworkManager.SecretAgent.UserCanceled"


def _unpack(value):
    if isinstance(value, Variant):
        return _unpack(value.value)
    if isinstance(value, GLib.Variant):
        return _unpack(value.unpack())
    if isinstance(value, dict):
        return {key: _unpack(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return type(value)(_unpack(item) for item in value)
    return value


class PortalColorScheme:
    def __init__(self):
        self.style_manager = Adw.StyleManager.get_default()
        self.proxy = None
        try:
            self.proxy = Gio.DBusProxy.new_for_bus_sync(
                Gio.BusType.SESSION,
                Gio.DBusProxyFlags.DO_NOT_AUTO_START,
                None,
                "org.freedesktop.portal.Desktop",
                "/org/freedesktop/portal/desktop",
                "org.freedesktop.portal.Settings",
                None,
            )
            self.proxy.connect("g-signal", self._on_signal)
            result = self.proxy.call_sync(
                "Read",
                GLib.Variant("(ss)", ("org.freedesktop.appearance", "color-scheme")),
                Gio.DBusCallFlags.NONE,
                2000,
                None,
            )
            self._apply(_unpack(result.unpack()[0]))
        except GLib.Error:
            self.style_manager.set_color_scheme(Adw.ColorScheme.DEFAULT)

    def _on_signal(self, _proxy, _sender, signal_name, parameters):
        if signal_name != "SettingChanged":
            return
        namespace, key, value = parameters.unpack()
        if namespace == "org.freedesktop.appearance" and key == "color-scheme":
            self._apply(_unpack(value))

    def _apply(self, color_scheme):
        if color_scheme == 1:
            scheme = Adw.ColorScheme.FORCE_DARK
        elif color_scheme == 2:
            scheme = Adw.ColorScheme.FORCE_LIGHT
        else:
            scheme = Adw.ColorScheme.DEFAULT
        self.style_manager.set_color_scheme(scheme)


class PasswordWindow(Adw.ApplicationWindow):
    def __init__(self, application, profile_name, gateway, username):
        super().__init__(application=application)
        self.agent = application
        self.set_title("Connect to Fortinet VPN")
        self.set_default_size(480, 330)
        self.set_size_request(420, 280)
        self.connect("close-request", self._close_requested)

        cancel = Gtk.Button(label="Cancel")
        cancel.connect("clicked", self._cancel)
        connect = Gtk.Button(label="Connect")
        connect.add_css_class("suggested-action")
        connect.connect("clicked", self._connect)

        header = Adw.HeaderBar()
        header.pack_start(cancel)
        header.pack_end(connect)

        self.banner = Adw.Banner()
        self.banner.set_revealed(False)

        details = []
        if gateway:
            details.append(gateway)
        if username:
            details.append(f"User: {username}")
        group = Adw.PreferencesGroup(
            title=profile_name or "Fortinet VPN",
            description=" • ".join(details),
        )
        self.password = Adw.PasswordEntryRow(title="VPN password")
        self.password.connect("entry-activated", self._connect)
        group.add(self.password)

        page = Adw.PreferencesPage()
        page.set_description(
            "Enter the password for this connection attempt. The password will not be saved."
        )
        page.add(group)

        toolbar = Adw.ToolbarView()
        toolbar.add_top_bar(header)
        toolbar.add_top_bar(self.banner)
        toolbar.set_content(page)
        self.set_content(toolbar)

    def _connect(self, _widget):
        password = self.password.get_text()
        if not password:
            self.banner.set_title("VPN password is required.")
            self.banner.set_revealed(True)
            return
        if len(password) > 4096:
            self.banner.set_title("VPN password is too long.")
            self.banner.set_revealed(True)
            return
        self.agent.complete_prompt(password)

    def _cancel(self, _button):
        self.agent.cancel_prompt()

    def _close_requested(self, _window):
        self.agent.cancel_prompt(destroy_window=False)
        return False


class SecretAgentInterface(ServiceInterface):
    def __init__(self, application):
        super().__init__(NM_AGENT_INTERFACE)
        self.application = application

    @method()
    async def GetSecrets(
        self,
        connection: "a{sa{sv}}",
        connection_path: "o",
        setting_name: "s",
        hints: "as",
        flags: "u",
    ) -> "a{sa{sv}}":
        del hints
        settings = _unpack(connection)
        vpn = settings.get("vpn", {})
        connection_setting = settings.get("connection", {})
        user_data = settings.get("user", {}).get("data", {})
        interaction_allowed = flags & (ALLOW_INTERACTION | REQUEST_NEW)
        valid_request = (
            setting_name == "vpn"
            and vpn.get("service-type") == FORTISSLVPN_SERVICE_TYPE
            and vpn.get("data", {}).get("password-flags") == "2"
            and user_data.get(PROFILE_MARKER) == "true"
            and interaction_allowed
            and flags & USER_REQUESTED
        )
        if not valid_request:
            raise DBusError(
                NO_SECRETS,
                "No stored secrets are available for this request",
            )

        event_loop = asyncio.get_running_loop()
        password_future = event_loop.create_future()
        GLib.idle_add(
            self.application.begin_prompt,
            connection_path,
            setting_name,
            connection_setting.get("id", "Fortinet VPN"),
            vpn.get("data", {}).get("gateway", ""),
            vpn.get("data", {}).get("user", ""),
            event_loop,
            password_future,
        )
        password = await password_future
        return {"vpn": {"password": Variant("s", password)}}

    @method()
    def CancelGetSecrets(self, connection_path: "o", setting_name: "s"):
        GLib.idle_add(
            self.application.cancel_networkmanager_request,
            connection_path,
            setting_name,
        )

    @method()
    def SaveSecrets(self, connection: "a{sa{sv}}", connection_path: "o"):
        # This agent deliberately has no persistent secret store.
        del connection, connection_path

    @method()
    def DeleteSecrets(self, connection: "a{sa{sv}}", connection_path: "o"):
        del connection, connection_path


async def _register_agent(bus):
    reply = await bus.call(
        Message(
            destination=NM_BUS_NAME,
            path=NM_AGENT_MANAGER_PATH,
            interface=NM_AGENT_MANAGER_INTERFACE,
            member="Register",
            signature="s",
            body=[APPLICATION_ID],
        )
    )
    if reply.message_type == MessageType.ERROR:
        detail = reply.body[0] if reply.body else reply.error_name
        raise RuntimeError(detail or "NetworkManager SecretAgent registration failed")


async def _unregister_agent(bus):
    await bus.call(
        Message(
            destination=NM_BUS_NAME,
            path=NM_AGENT_MANAGER_PATH,
            interface=NM_AGENT_MANAGER_INTERFACE,
            member="Unregister",
        )
    )


async def run_agent(application):
    while not application.stop_event.is_set():
        try:
            bus = await MessageBus(bus_type=BusType.SYSTEM).connect()
            interface = SecretAgentInterface(application)
            bus.export(NM_AGENT_PATH, interface)

            registration_lock = asyncio.Lock()
            registration_state = {"registered": False}

            async def register_with_retry():
                if registration_state["registered"]:
                    return
                async with registration_lock:
                    if registration_state["registered"]:
                        return
                    while not application.stop_event.is_set():
                        try:
                            await _register_agent(bus)
                            registration_state["registered"] = True
                            return
                        except Exception as error:
                            print(
                                f"Fortinet SecretAgent registration failed: {error}",
                                file=sys.stderr,
                            )
                            await asyncio.sleep(2)

            def message_handler(message):
                if (
                    message.message_type == MessageType.SIGNAL
                    and message.interface == "org.freedesktop.DBus"
                    and message.member == "NameOwnerChanged"
                    and message.body[0] == NM_BUS_NAME
                ):
                    registration_state["registered"] = False
                    if message.body[2]:
                        asyncio.create_task(register_with_retry())

            bus.add_message_handler(message_handler)
            await register_with_retry()
            while not application.stop_event.is_set():
                await asyncio.sleep(0.5)
            if registration_state["registered"]:
                await _unregister_agent(bus)
            bus.disconnect()
        except Exception as error:
            if not application.stop_event.is_set():
                print(
                    f"Fortinet SecretAgent connection failed: {error}", file=sys.stderr
                )
                await asyncio.sleep(2)


class FortiVpnSecretAgent(Adw.Application):
    def __init__(self):
        super().__init__(
            application_id=APPLICATION_ID,
            flags=Gio.ApplicationFlags.NON_UNIQUE,
        )
        self.stop_event = threading.Event()
        self.agent_thread = None
        self.pending = None
        self.prompt_window = None
        self.color_scheme = None

    def do_startup(self):
        Adw.Application.do_startup(self)
        self.hold()
        self.color_scheme = PortalColorScheme()
        self.agent_thread = threading.Thread(
            target=lambda: asyncio.run(run_agent(self)),
            name="fortivpn-secret-agent",
            daemon=True,
        )
        self.agent_thread.start()

    def do_activate(self):
        # The application remains in the session and only displays a window in
        # response to an interactive NetworkManager secret request.
        pass

    def do_shutdown(self):
        self.stop_event.set()
        if self.pending:
            self._finish_prompt(error=DBusError(USER_CANCELED, "Session ended"))
        if self.agent_thread:
            self.agent_thread.join(timeout=3)
        self.release()
        Adw.Application.do_shutdown(self)

    def begin_prompt(
        self,
        connection_path,
        setting_name,
        profile_name,
        gateway,
        username,
        event_loop,
        password_future,
    ):
        if self.pending:
            event_loop.call_soon_threadsafe(
                password_future.set_exception,
                DBusError(
                    NO_SECRETS,
                    "Another Fortinet VPN password request is already active",
                ),
            )
            return False

        self.pending = {
            "connection_path": connection_path,
            "setting_name": setting_name,
            "event_loop": event_loop,
            "future": password_future,
        }
        self.prompt_window = PasswordWindow(
            self,
            profile_name,
            gateway,
            username,
        )
        self.prompt_window.present()
        self.prompt_window.password.grab_focus()
        return False

    def complete_prompt(self, password):
        self._finish_prompt(result=password)

    def cancel_prompt(self, destroy_window=True):
        self._finish_prompt(
            error=DBusError(USER_CANCELED, "The VPN connection was canceled"),
            destroy_window=destroy_window,
        )

    def cancel_networkmanager_request(self, connection_path, setting_name):
        if self.pending and (
            self.pending["connection_path"] == connection_path
            and self.pending["setting_name"] == setting_name
        ):
            self.cancel_prompt()
        return False

    def _finish_prompt(self, result=None, error=None, destroy_window=True):
        if not self.pending:
            return
        pending = self.pending
        window = self.prompt_window
        self.pending = None
        self.prompt_window = None
        if window is not None:
            window.password.set_text("")
            if destroy_window:
                window.destroy()
        callback = (
            pending["future"].set_exception if error else pending["future"].set_result
        )
        pending["event_loop"].call_soon_threadsafe(callback, error or result)


def main():
    application = FortiVpnSecretAgent()
    return application.run(sys.argv)


if __name__ == "__main__":
    raise SystemExit(main())

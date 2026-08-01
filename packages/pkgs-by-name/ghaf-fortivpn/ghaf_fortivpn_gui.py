#!/usr/bin/env python3
# ruff: noqa: E402
# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

import os
import re
import sys
from pathlib import Path

import gi

gi.require_version("Adw", "1")
gi.require_version("Gtk", "4.0")

from gi.repository import Adw, Gio, GLib, Gtk


APPLICATION_ID = "org.ghaf.FortiVpn"
BUS_NAME = "org.ghaf.FortiVpn"
OBJECT_PATH = "/org/ghaf/FortiVpn"
INTERFACE_NAME = "org.ghaf.FortiVpn1"
COSMIC_SETTINGS = "@cosmic-settings@"

_MAX_PKCS12_SIZE = 10 * 1024 * 1024
_MAX_CA_SIZE = 2 * 1024 * 1024
_GATEWAY_RE = re.compile(
    r"^(?:[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?|"
    r"\[[0-9A-Fa-f:.]+\])$"
)
_REALM_RE = re.compile(r"^[A-Za-z0-9._-]*$")
_FINGERPRINT_RE = re.compile(r"^[0-9A-Fa-f]{64}$")


class InputError(Exception):
    pass


def _variant_value(value):
    while isinstance(value, GLib.Variant):
        value = value.unpack()
    return value


class PortalColorScheme:
    """Keep libadwaita in sync with the desktop portal light/dark preference."""

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
                GLib.Variant(
                    "(ss)",
                    ("org.freedesktop.appearance", "color-scheme"),
                ),
                Gio.DBusCallFlags.NONE,
                2000,
                None,
            )
            self._apply(_variant_value(result.unpack()[0]))
        except GLib.Error:
            # Libadwaita's default preference remains a safe fallback when the
            # desktop portal is unavailable.
            self.style_manager.set_color_scheme(Adw.ColorScheme.DEFAULT)

    def _on_signal(self, _proxy, _sender, signal_name, parameters):
        if signal_name != "SettingChanged":
            return

        namespace, key, value = parameters.unpack()
        if namespace == "org.freedesktop.appearance" and key == "color-scheme":
            self._apply(_variant_value(value))

    def _apply(self, color_scheme):
        if color_scheme == 1:
            scheme = Adw.ColorScheme.FORCE_DARK
        elif color_scheme == 2:
            scheme = Adw.ColorScheme.FORCE_LIGHT
        else:
            scheme = Adw.ColorScheme.DEFAULT
        self.style_manager.set_color_scheme(scheme)


class FortiVpnWindow(Adw.ApplicationWindow):
    def __init__(self, application):
        super().__init__(application=application)
        self.set_title("Fortinet VPN")
        self.set_default_size(680, 760)
        self.set_size_request(460, 560)

        self.pkcs12_path = None
        self.ca_path = None
        self.file_chooser = None
        self.color_scheme = PortalColorScheme()

        self.save_button = Gtk.Button(label="Add VPN")
        self.save_button.add_css_class("suggested-action")
        self.save_button.connect("clicked", self._configure)

        header = Adw.HeaderBar()
        header.pack_end(self.save_button)

        self.banner = Adw.Banner()
        self.banner.set_revealed(False)
        self.banner.connect("button-clicked", self._open_vpn_settings)

        toolbar = Adw.ToolbarView()
        toolbar.add_top_bar(header)
        toolbar.add_top_bar(self.banner)
        toolbar.set_content(self._preferences())
        self.set_content(toolbar)

    def _preferences(self):
        page = Adw.PreferencesPage()
        page.set_title("Fortinet VPN")
        page.set_description(
            "Create a Fortinet SSL VPN profile. The connection will appear "
            "in Network & Wireless after it is added."
        )

        connection = Adw.PreferencesGroup(title="Connection")
        page.add(connection)

        self.name = Adw.EntryRow(title="Connection name")
        self.name.set_text("Fortinet VPN")
        connection.add(self.name)

        self.gateway = Adw.EntryRow(title="Gateway")
        connection.add(self.gateway)

        self.port = Adw.SpinRow.new_with_range(1, 65535, 1)
        self.port.set_title("Port")
        self.port.set_value(443)
        connection.add(self.port)

        self.realm = Adw.EntryRow(title="Realm")
        connection.add(self.realm)

        authentication = Adw.PreferencesGroup(
            title="Authentication",
            description=(
                "Your VPN password will be requested when you connect. It is sent "
                "to NetworkManager for that connection attempt and is never saved."
            ),
        )
        page.add(authentication)

        self.username = Adw.EntryRow(title="Username")
        authentication.add(self.username)

        self.trusted_certificate = Adw.EntryRow(title="Trusted gateway certificate")
        authentication.add(self.trusted_certificate)

        certificates = Adw.PreferencesGroup(
            title="Certificates",
            description=(
                "Certificates are validated and transferred securely to Net VM. "
                "The original PKCS#12 file and import password are not retained."
            ),
        )
        page.add(certificates)

        self.pkcs12_row, self.pkcs12_button, self.pkcs12_clear = self._file_row(
            "Client certificate",
            "Optional PKCS#12 or PFX file",
            self._choose_pkcs12,
            self._clear_pkcs12,
        )
        certificates.add(self.pkcs12_row)

        self.pkcs12_password = Adw.PasswordEntryRow(title="PKCS#12 import password")
        self.pkcs12_password.set_sensitive(False)
        certificates.add(self.pkcs12_password)

        self.ca_row, self.ca_button, self.ca_clear = self._file_row(
            "Gateway CA certificate",
            "Optional PEM, CRT, or CER file",
            self._choose_ca,
            self._clear_ca,
        )
        certificates.add(self.ca_row)

        return page

    @staticmethod
    def _file_row(title, subtitle, choose_callback, clear_callback):
        row = Adw.ActionRow(title=title, subtitle=subtitle)

        clear = Gtk.Button.new_from_icon_name("edit-clear-symbolic")
        clear.set_tooltip_text(f"Clear {title.lower()}")
        clear.set_valign(Gtk.Align.CENTER)
        clear.set_visible(False)
        clear.connect("clicked", clear_callback)
        row.add_suffix(clear)

        choose = Gtk.Button(label="Choose…")
        choose.set_valign(Gtk.Align.CENTER)
        choose.connect("clicked", choose_callback)
        row.add_suffix(choose)
        row.set_activatable_widget(choose)

        return row, choose, clear

    def _choose_pkcs12(self, _button):
        self._choose_file(
            "Choose a client certificate",
            "PKCS#12 certificates",
            ("*.p12", "*.pfx"),
            self._set_pkcs12,
        )

    def _choose_ca(self, _button):
        self._choose_file(
            "Choose a gateway CA certificate",
            "CA certificates",
            ("*.pem", "*.crt", "*.cer"),
            self._set_ca,
        )

    def _choose_file(self, title, filter_name, patterns, callback):
        chooser = Gtk.FileChooserNative.new(
            title,
            self,
            Gtk.FileChooserAction.OPEN,
            "Choose",
            "Cancel",
        )
        file_filter = Gtk.FileFilter()
        file_filter.set_name(filter_name)
        for pattern in patterns:
            file_filter.add_pattern(pattern)
        chooser.add_filter(file_filter)
        chooser.connect("response", self._file_chosen, callback)
        self.file_chooser = chooser
        chooser.show()

    def _file_chosen(self, chooser, response, callback):
        if response == Gtk.ResponseType.ACCEPT:
            selected = chooser.get_file()
            path = selected.get_path() if selected is not None else None
            if path is None:
                self._show_error("Only local certificate files can be used.")
            else:
                callback(path)
        chooser.destroy()
        self.file_chooser = None

    def _set_pkcs12(self, path):
        self.pkcs12_path = path
        self.pkcs12_row.set_subtitle(Path(path).name)
        self.pkcs12_button.set_label("Change…")
        self.pkcs12_clear.set_visible(True)
        self.pkcs12_password.set_sensitive(True)
        self.pkcs12_password.grab_focus()

    def _clear_pkcs12(self, _button=None):
        self.pkcs12_path = None
        self.pkcs12_row.set_subtitle("Optional PKCS#12 or PFX file")
        self.pkcs12_button.set_label("Choose…")
        self.pkcs12_clear.set_visible(False)
        self.pkcs12_password.set_text("")
        self.pkcs12_password.set_sensitive(False)

    def _set_ca(self, path):
        self.ca_path = path
        self.ca_row.set_subtitle(Path(path).name)
        self.ca_button.set_label("Change…")
        self.ca_clear.set_visible(True)

    def _clear_ca(self, _button=None):
        self.ca_path = None
        self.ca_row.set_subtitle("Optional PEM, CRT, or CER file")
        self.ca_button.set_label("Choose…")
        self.ca_clear.set_visible(False)

    @staticmethod
    def _read_file(path, maximum_size, label):
        if path is None:
            return b""

        try:
            size = os.path.getsize(path)
            if size > maximum_size:
                raise InputError(
                    f"{label} is too large. The maximum size is "
                    f"{maximum_size // (1024 * 1024)} MiB."
                )
            with open(path, "rb") as source:
                return source.read()
        except OSError as error:
            raise InputError(f"Could not read {label.lower()}: {error}") from error

    def _request(self):
        name = self.name.get_text().strip()
        gateway = self.gateway.get_text().strip()
        port = str(int(self.port.get_value()))
        realm = self.realm.get_text().strip()
        username = self.username.get_text().strip()
        trusted_certificate = (
            self.trusted_certificate.get_text().replace(":", "").strip().upper()
        )

        if not name:
            raise InputError("Connection name is required.")
        if not gateway or not _GATEWAY_RE.fullmatch(gateway):
            raise InputError(
                "Gateway must be a hostname or IP address without https:// or a path."
            )
        if not _REALM_RE.fullmatch(realm):
            raise InputError(
                "Realm may contain only letters, numbers, dots, underscores, "
                "and hyphens."
            )
        if trusted_certificate and not _FINGERPRINT_RE.fullmatch(trusted_certificate):
            raise InputError(
                "Trusted gateway certificate must be a 64-character SHA-256 "
                "fingerprint."
            )

        pkcs12_data = self._read_file(
            self.pkcs12_path,
            _MAX_PKCS12_SIZE,
            "PKCS#12 certificate",
        )
        ca_data = self._read_file(
            self.ca_path,
            _MAX_CA_SIZE,
            "CA certificate",
        )

        return GLib.Variant(
            "(ssssssaysay)",
            (
                name,
                gateway,
                port,
                realm,
                username,
                trusted_certificate,
                pkcs12_data,
                self.pkcs12_password.get_text() if pkcs12_data else "",
                ca_data,
            ),
        )

    def _configure(self, _button):
        self.banner.set_revealed(False)
        try:
            request = self._request()
            proxy = Gio.DBusProxy.new_for_bus_sync(
                Gio.BusType.SYSTEM,
                Gio.DBusProxyFlags.NONE,
                None,
                BUS_NAME,
                OBJECT_PATH,
                INTERFACE_NAME,
                None,
            )
        except (InputError, GLib.Error) as error:
            self._show_error(str(error))
            return

        self._set_busy(True)
        proxy.call(
            "Configure",
            request,
            Gio.DBusCallFlags.NONE,
            60000,
            None,
            self._configured,
            proxy,
        )

    def _configured(self, proxy, result, _proxy):
        self._set_busy(False)
        self.pkcs12_password.set_text("")
        try:
            proxy.call_finish(result)
        except GLib.Error as error:
            message = error.message.rsplit(": ", maxsplit=1)[-1]
            self._show_error(message)
            return

        self.banner.set_title(
            "VPN profile created. It is now available in Network & Wireless → VPN."
        )
        self.banner.set_button_label("Open VPN Settings")
        self.banner.set_revealed(True)

    def _set_busy(self, busy):
        self.save_button.set_sensitive(not busy)
        self.save_button.set_label("Adding…" if busy else "Add VPN")

    def _show_error(self, message):
        self.banner.set_title(message)
        self.banner.set_button_label("")
        self.banner.set_revealed(True)

    def _open_vpn_settings(self, _banner):
        try:
            Gio.Subprocess.new(
                [COSMIC_SETTINGS, "vpn"],
                Gio.SubprocessFlags.NONE,
            )
        except GLib.Error as error:
            self._show_error(f"Could not open VPN Settings: {error.message}")


class FortiVpnApplication(Adw.Application):
    def __init__(self):
        super().__init__(
            application_id=APPLICATION_ID,
            flags=Gio.ApplicationFlags.DEFAULT_FLAGS,
        )
        self.window = None

    def do_activate(self):
        if self.window is None:
            self.window = FortiVpnWindow(self)
        self.window.present()


def main():
    application = FortiVpnApplication()
    return application.run(sys.argv)


if __name__ == "__main__":
    raise SystemExit(main())

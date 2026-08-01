#!/usr/bin/env python3
# ruff: noqa: F821
# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

import argparse
import asyncio
import hashlib
import os
import re
import shutil
import subprocess
import tempfile
import uuid
from pathlib import Path

from dbus_next import BusType, DBusError, Message, MessageType, Variant
from dbus_next.aio import MessageBus
from dbus_next.service import ServiceInterface, method


BUS_NAME = "org.ghaf.FortiVpn"
OBJECT_PATH = "/org/ghaf/FortiVpn"
INTERFACE_NAME = "org.ghaf.FortiVpn1"
NM_BUS_NAME = "org.freedesktop.NetworkManager"
NM_SETTINGS_PATH = "/org/freedesktop/NetworkManager/Settings"
NM_SETTINGS_INTERFACE = "org.freedesktop.NetworkManager.Settings"
NM_CONNECTION_INTERFACE = "org.freedesktop.NetworkManager.Settings.Connection"
FORTISSLVPN_SERVICE_TYPE = "org.freedesktop.NetworkManager.fortisslvpn"
PROFILE_MARKER = "org.ghaf.fortivpn"
NMCLI = "@nmcli@"
OPENSSL = "@openssl@"
STATE_ROOT = Path("/var/lib/ghaf/fortivpn")

_UUID_RE = re.compile(
    r"^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
)
_GATEWAY_RE = re.compile(
    r"^(?:[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?|"
    r"\[[0-9A-Fa-f:.]+\])$"
)
_REALM_RE = re.compile(r"^[A-Za-z0-9._-]*$")
_FINGERPRINT_RE = re.compile(r"^[0-9A-Fa-f]{64}$")
_MAX_PKCS12_SIZE = 10 * 1024 * 1024
_MAX_CA_SIZE = 2 * 1024 * 1024


class ConfigurationError(Exception):
    pass


def _run(command, *, input_data=None):
    try:
        return subprocess.run(
            command,
            input=input_data,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
            timeout=30,
        )
    except subprocess.CalledProcessError as error:
        detail = error.stderr.decode("utf-8", errors="replace").strip()
        if not detail:
            detail = f"{Path(command[0]).name} exited with status {error.returncode}"
        raise ConfigurationError(detail) from error
    except subprocess.TimeoutExpired as error:
        raise ConfigurationError(
            f"{Path(command[0]).name} did not finish within 30 seconds"
        ) from error


def _validate_plain_text(label, value, *, maximum, allow_empty=False):
    if not value and allow_empty:
        return
    if not value:
        raise ConfigurationError(f"{label} is required")
    if len(value) > maximum:
        raise ConfigurationError(f"{label} is too long")
    if any(ord(character) < 32 or character == "," for character in value):
        raise ConfigurationError(f"{label} contains an unsupported character")


def validate_configuration(name, gateway, port, realm, username, trusted_cert):
    _validate_plain_text("Connection name", name, maximum=100)
    _validate_plain_text("Gateway", gateway, maximum=253)
    _validate_plain_text("Realm", realm, maximum=128, allow_empty=True)
    _validate_plain_text("Username", username, maximum=256, allow_empty=True)

    if not _GATEWAY_RE.fullmatch(gateway):
        raise ConfigurationError(
            "Gateway must be a hostname or IP address without a URL scheme or path"
        )

    try:
        numeric_port = int(port)
    except ValueError as error:
        raise ConfigurationError("Port must be a number") from error
    if not 1 <= numeric_port <= 65535:
        raise ConfigurationError("Port must be between 1 and 65535")

    if not _REALM_RE.fullmatch(realm):
        raise ConfigurationError(
            "Realm may contain only letters, numbers, dots, underscores, and hyphens"
        )

    if trusted_cert and not _FINGERPRINT_RE.fullmatch(trusted_cert):
        raise ConfigurationError(
            "Trusted certificate must be a 64-character SHA-256 fingerprint"
        )


def _extract_pkcs12(pkcs12_data, password, work_dir):
    if len(pkcs12_data) > _MAX_PKCS12_SIZE:
        raise ConfigurationError("The PKCS#12 file is larger than 10 MiB")

    source = work_dir / "client.p12"
    raw_certificate = work_dir / "raw-client-cert.pem"
    raw_key = work_dir / "raw-client-key.pem"
    certificate = work_dir / "client-cert.pem"
    key = work_dir / "client-key.pem"
    source.write_bytes(pkcs12_data)
    os.chmod(source, 0o600)
    passphrase = password.encode("utf-8") + b"\n"

    def extract(arguments):
        normal = [OPENSSL, "pkcs12", "-in", str(source), *arguments, "-passin", "stdin"]
        try:
            _run(normal, input_data=passphrase)
        except ConfigurationError as first_error:
            legacy = [
                OPENSSL,
                "pkcs12",
                "-legacy",
                "-in",
                str(source),
                *arguments,
                "-passin",
                "stdin",
            ]
            try:
                _run(legacy, input_data=passphrase)
            except ConfigurationError:
                raise first_error

    extract(["-clcerts", "-nokeys", "-out", str(raw_certificate)])
    extract(["-nocerts", "-nodes", "-out", str(raw_key)])

    _run([OPENSSL, "x509", "-in", str(raw_certificate), "-out", str(certificate)])
    _run([OPENSSL, "pkey", "-in", str(raw_key), "-out", str(key)])
    _run([OPENSSL, "x509", "-in", str(certificate), "-checkend", "0", "-noout"])

    certificate_public_key = _run(
        [OPENSSL, "x509", "-in", str(certificate), "-pubkey", "-noout"]
    ).stdout
    certificate_public_der = _run(
        [OPENSSL, "pkey", "-pubin", "-outform", "DER"],
        input_data=certificate_public_key,
    ).stdout
    key_public_der = _run(
        [OPENSSL, "pkey", "-in", str(key), "-pubout", "-outform", "DER"]
    ).stdout
    if (
        hashlib.sha256(certificate_public_der).digest()
        != hashlib.sha256(key_public_der).digest()
    ):
        raise ConfigurationError("The client certificate and private key do not match")

    source.unlink()
    raw_certificate.unlink()
    raw_key.unlink()
    os.chmod(certificate, 0o600)
    os.chmod(key, 0o600)
    return certificate, key


def _import_ca(ca_data, work_dir):
    if len(ca_data) > _MAX_CA_SIZE:
        raise ConfigurationError("The CA certificate is larger than 2 MiB")

    source = work_dir / "gateway-ca.input"
    destination = work_dir / "gateway-ca.pem"
    source.write_bytes(ca_data)
    os.chmod(source, 0o600)
    try:
        _run([OPENSSL, "x509", "-in", str(source), "-out", str(destination)])
    except ConfigurationError as pem_error:
        try:
            _run(
                [
                    OPENSSL,
                    "x509",
                    "-inform",
                    "DER",
                    "-in",
                    str(source),
                    "-out",
                    str(destination),
                ]
            )
        except ConfigurationError:
            raise pem_error
    source.unlink()
    # NetworkManager-fortisslvpn rejects a CA path unless the file has all
    # read bits set. The containing profile directory remains root-only.
    os.chmod(destination, 0o444)
    _run([OPENSSL, "x509", "-in", str(destination), "-checkend", "0", "-noout"])
    return destination


def _connection_names():
    result = _run([NMCLI, "-g", "NAME", "connection", "show"])
    return set(result.stdout.decode("utf-8", errors="replace").splitlines())


async def _add_connection(bus, profile_uuid, name, vpn_data):
    settings = {
        "connection": {
            "id": Variant("s", name),
            "uuid": Variant("s", profile_uuid),
            "type": Variant("s", "vpn"),
            "autoconnect": Variant("b", False),
        },
        "vpn": {
            "service-type": Variant("s", FORTISSLVPN_SERVICE_TYPE),
            "data": Variant("a{ss}", vpn_data),
        },
        "user": {
            "data": Variant("a{ss}", {PROFILE_MARKER: "true"}),
        },
    }
    reply = await bus.call(
        Message(
            destination=NM_BUS_NAME,
            path=NM_SETTINGS_PATH,
            interface=NM_SETTINGS_INTERFACE,
            member="AddConnection",
            signature="a{sa{sv}}",
            body=[settings],
        )
    )
    if reply.message_type == MessageType.ERROR:
        detail = reply.body[0] if reply.body else reply.error_name
        raise ConfigurationError(detail or "NetworkManager rejected the VPN profile")


async def provision_profile(
    bus,
    name,
    gateway,
    port,
    realm,
    username,
    trusted_cert,
    pkcs12_data,
    pkcs12_password,
    ca_data,
):
    validate_configuration(name, gateway, port, realm, username, trusted_cert)
    pkcs12_data = bytes(pkcs12_data)
    ca_data = bytes(ca_data)

    if not pkcs12_data and pkcs12_password:
        raise ConfigurationError(
            "A PKCS#12 import password was provided without a PKCS#12 file"
        )
    if name in _connection_names():
        raise ConfigurationError(f'A connection named "{name}" already exists')

    profile_uuid = str(uuid.uuid4())
    STATE_ROOT.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(STATE_ROOT, 0o700)
    temporary_directory = Path(
        tempfile.mkdtemp(prefix=f".{profile_uuid}.", dir=STATE_ROOT)
    )
    os.chmod(temporary_directory, 0o700)
    final_directory = STATE_ROOT / profile_uuid

    try:
        certificate = key = ca_certificate = None
        if pkcs12_data:
            certificate, key = _extract_pkcs12(
                pkcs12_data, pkcs12_password, temporary_directory
            )
        if ca_data:
            ca_certificate = _import_ca(ca_data, temporary_directory)

        if certificate or ca_certificate:
            temporary_directory.rename(final_directory)
        else:
            temporary_directory.rmdir()

        vpn_data = {
            "gateway": f"{gateway}:{int(port)}",
            "password-flags": "2",
        }
        if realm:
            vpn_data["realm"] = realm
        if username:
            vpn_data["user"] = username
        if trusted_cert:
            vpn_data["trusted-cert"] = trusted_cert.lower()
        if certificate:
            vpn_data["cert"] = str(final_directory / certificate.name)
            vpn_data["key"] = str(final_directory / key.name)
        if ca_certificate:
            vpn_data["ca"] = str(final_directory / ca_certificate.name)

        await _add_connection(bus, profile_uuid, name, vpn_data)
    except Exception:
        shutil.rmtree(temporary_directory, ignore_errors=True)
        shutil.rmtree(final_directory, ignore_errors=True)
        raise

    return profile_uuid


async def _call_networkmanager(
    bus, *, path, interface, member, signature="", body=None
):
    reply = await bus.call(
        Message(
            destination=NM_BUS_NAME,
            path=path,
            interface=interface,
            member=member,
            signature=signature,
            body=body or [],
        )
    )
    if reply.message_type == MessageType.ERROR:
        detail = reply.body[0] if reply.body else reply.error_name
        raise ConfigurationError(detail or f"NetworkManager {member} failed")
    return reply


async def migrate_fortisslvpn_secrets(bus):
    """Clear persisted passwords and mark existing Fortinet profiles not-saved."""
    reply = await _call_networkmanager(
        bus,
        path=NM_SETTINGS_PATH,
        interface=NM_SETTINGS_INTERFACE,
        member="ListConnections",
    )

    for connection_path in reply.body[0]:
        settings_reply = await _call_networkmanager(
            bus,
            path=connection_path,
            interface=NM_CONNECTION_INTERFACE,
            member="GetSettings",
        )
        settings = settings_reply.body[0]
        vpn = settings.get("vpn", {})
        service_type = vpn.get("service-type")
        if service_type is None or service_type.value != FORTISSLVPN_SERVICE_TYPE:
            continue

        vpn_data_variant = vpn.get("data")
        vpn_data = dict(vpn_data_variant.value) if vpn_data_variant else {}
        # ClearSecrets runs first so a failed settings update cannot leave a
        # readable password behind.
        await _call_networkmanager(
            bus,
            path=connection_path,
            interface=NM_CONNECTION_INTERFACE,
            member="ClearSecrets",
        )

        user = settings.setdefault("user", {})
        user_data_variant = user.get("data")
        user_data = dict(user_data_variant.value) if user_data_variant else {}
        needs_update = (
            vpn_data.get("password-flags") != "2"
            or user_data.get(PROFILE_MARKER) != "true"
        )
        if not needs_update:
            continue

        vpn_data["password-flags"] = "2"
        vpn["data"] = Variant("a{ss}", vpn_data)
        vpn.pop("secrets", None)
        user_data[PROFILE_MARKER] = "true"
        user["data"] = Variant("a{ss}", user_data)
        await _call_networkmanager(
            bus,
            path=connection_path,
            interface=NM_CONNECTION_INTERFACE,
            member="Update2",
            signature="a{sa{sv}}ua{sv}",
            body=[settings, 1, {}],
        )


def garbage_collect():
    try:
        result = _run([NMCLI, "-t", "-f", "UUID", "connection", "show"])
    except ConfigurationError:
        return 0

    active_uuids = set(
        result.stdout.decode("utf-8", errors="replace").strip().splitlines()
    )
    removed = 0
    if not STATE_ROOT.exists():
        return removed

    for candidate in STATE_ROOT.iterdir():
        if (
            candidate.is_dir()
            and _UUID_RE.fullmatch(candidate.name)
            and candidate.name not in active_uuids
        ):
            shutil.rmtree(candidate)
            removed += 1
    return removed


class FortiVpnInterface(ServiceInterface):
    def __init__(self, bus):
        super().__init__(INTERFACE_NAME)
        self.bus = bus

    @method()
    async def Configure(
        self,
        name: "s",
        gateway: "s",
        port: "s",
        realm: "s",
        username: "s",
        trusted_cert: "s",
        pkcs12_data: "ay",
        pkcs12_password: "s",
        ca_data: "ay",
    ) -> "s":
        try:
            return await provision_profile(
                self.bus,
                name,
                gateway,
                port,
                realm,
                username,
                trusted_cert,
                pkcs12_data,
                pkcs12_password,
                ca_data,
            )
        except ConfigurationError as error:
            raise DBusError(
                "org.ghaf.FortiVpn.Error.InvalidConfiguration", str(error)
            ) from error
        except Exception as error:
            raise DBusError(
                "org.ghaf.FortiVpn.Error.Failed",
                "The Fortinet VPN profile could not be created",
            ) from error


async def run_service():
    bus = await MessageBus(bus_type=BusType.SYSTEM).connect()
    await migrate_fortisslvpn_secrets(bus)
    bus.export(OBJECT_PATH, FortiVpnInterface(bus))
    await bus.request_name(BUS_NAME)
    await asyncio.get_running_loop().create_future()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--gc",
        action="store_true",
        help="remove certificate directories whose NetworkManager profile was deleted",
    )
    arguments = parser.parse_args()
    if arguments.gc:
        garbage_collect()
    else:
        asyncio.run(run_service())


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Run the WARP proxy, recover its children, and check tunneled egress."""
import argparse
from dataclasses import dataclass
import hashlib
import ipaddress
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import threading
import time
from urllib.parse import urlsplit

STATE_DIR = Path('/var/lib/cloudflare-warp')
RUNTIME_DIRS = (Path('/run/dbus'), Path('/run/cloudflare-warp'))
STALE_FILES = (Path('/run/dbus/pid'), Path('/run/dbus/system_bus_socket'),
               Path('/run/cloudflare-warp/warp_service'), Path('/run/cloudflare-warp/warp-svc.pid'))


@dataclass(frozen=True)
class Config:
    port: int
    log_level: str
    protocol: str
    masque_options: str
    license: str
    connector_token: str
    endpoint: str
    check_url: str
    sleep_seconds: int
    restart_after_seconds: int

    @classmethod
    def from_env(cls):
        def integer(key, default, maximum=None):
            raw = os.environ.get(key, default)
            if not re.fullmatch(r'[0-9]+', raw):
                raise ValueError(f'{key} must be a positive integer')
            value = int(raw)
            if value < 1 or (maximum is not None and value > maximum):
                raise ValueError(f'{key} is outside its valid range')
            return value

        log_level = os.environ.get('WARP_LOG_LEVEL', 'error')
        protocol = os.environ.get('WARP_PROTOCOL', 'MASQUE')
        options = os.environ.get('WARP_MASQUE_OPTIONS', 'h3-with-h2-fallback')
        url = os.environ.get('CHECK_URL', 'https://cloudflare.com/cdn-cgi/trace')
        endpoint = os.environ.get('WARP_ENDPOINT', '')
        if log_level not in ('off', 'error', 'warn', 'info', 'debug', 'trace'):
            raise ValueError('Invalid WARP_LOG_LEVEL')
        if protocol not in ('MASQUE', 'WireGuard'):
            raise ValueError('WARP_PROTOCOL must be MASQUE or WireGuard')
        if options not in ('h3-with-h2-fallback', 'h3-only', 'h2-only'):
            raise ValueError('Invalid WARP_MASQUE_OPTIONS')
        if urlsplit(url).scheme not in ('https', 'http') or not urlsplit(url).hostname:
            raise ValueError('CHECK_URL must be an HTTP or HTTPS URL')
        if endpoint:
            host, separator, port = endpoint.rpartition(':')
            ipaddress.ip_address(host.strip('[]'))
            if not separator or not port.isdecimal() or not 1 <= int(port) <= 65535:
                raise ValueError('WARP_ENDPOINT must contain an IP address and valid port')
        return cls(integer('WARP_PORT', '40000', 65535), log_level, protocol, options,
                   os.environ.get('WARP_LICENSE', ''), os.environ.get('WARP_CONNECTOR_TOKEN', ''),
                   endpoint, url, integer('SLEEP_SECONDS', '60'), integer('RESTART_AFTER_SECONDS', '900'))


def run(arguments, timeout=10):
    try:
        return subprocess.run(arguments, text=True, capture_output=True, timeout=timeout, check=False)
    except (OSError, subprocess.SubprocessError):
        # Registration credentials can appear in arguments and command output.
        return subprocess.CompletedProcess(arguments[:1], 1, '', '')


def cli(*arguments):
    return run(['warp-cli', '--accept-tos', *arguments])


def require(*arguments):
    if cli(*arguments).returncode:
        raise RuntimeError(f'WARP command failed: {arguments[0]}')


def healthy(config):
    result = run(['curl', '--noproxy', '', '--connect-timeout', '5', '-m', '10', '-fsSLx',
                  f'socks5h://127.0.0.1:{config.port}', config.check_url], timeout=12)
    return result.returncode == 0 and re.search(r'^warp=(?:on|plus)\s*$', result.stdout, re.MULTILINE) is not None


def missing_registration(result):
    return re.search(r'Missing\s*Registration|Registration\s*Missing|not registered',
                     result.stdout + result.stderr, re.I) is not None


def connected_or_connecting(result):
    return result.returncode == 0 and re.search(
        r'^(?:Status update:\s*)?(?:Connected|Connecting)\s*$', result.stdout, re.MULTILINE) is not None


class Manager:
    def __init__(self, config):
        self.config = config
        self.stop = threading.Event()
        self.children = {}
        self.state = 'ipc'
        self.unhealthy_since = None

    def signal_stop(self, *_):
        self.stop.set()
        for process in self.children.values():
            if process.poll() is None:
                process.terminate()

    def start(self, name):
        if self.stop.is_set():
            return
        if name == 'dbus':
            for path in STALE_FILES[:2]:
                path.unlink(missing_ok=True)
            command = ['/usr/bin/dbus-daemon', '--system', '--nofork', '--nopidfile']
            environment = os.environ.copy()
        else:
            for path in STALE_FILES[2:]:
                path.unlink(missing_ok=True)
            command = ['/usr/bin/warp-svc']
            environment = dict(os.environ, LD_PRELOAD='/usr/local/lib/libbindany.so',
                               WARP_PORT=str(self.config.port), RUST_LOG=self.config.log_level)
        self.children[name] = subprocess.Popen(command, env=environment)
        self.state, self.unhealthy_since = 'ipc', None
        print(f'Started {name}', flush=True)

    def reap(self):
        while True:
            try:
                pid, status = os.waitpid(-1, os.WNOHANG)
            except ChildProcessError:
                return
            if pid == 0:
                return
            for process in self.children.values():
                if process.pid == pid:
                    process.returncode = os.waitstatus_to_exitcode(status)

    def terminate(self, name):
        process = self.children.get(name)
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()

    def step(self):
        config = self.config
        if self.state == 'ipc':
            result = cli('status')
            if (result.returncode == 0 or missing_registration(result)) and not re.search(
                    r'DaemonStartup|Connection refused|Unable to connect|Failed to connect',
                    result.stdout + result.stderr, re.I):
                self.state = 'registration'
        elif self.state == 'registration':
            result = cli('registration', 'show')
            fingerprint = STATE_DIR / '.applied_license_sha256'
            if result.returncode:
                if not missing_registration(result):
                    raise RuntimeError('Registration lookup failed')
                if config.connector_token:
                    require('connector', 'new', config.connector_token)
                else:
                    require('registration', 'new')
                fingerprint.unlink(missing_ok=True)
            if config.license:
                digest = hashlib.sha256(config.license.encode()).hexdigest()
                if not fingerprint.exists() or fingerprint.read_text().strip() != digest:
                    require('registration', 'license', config.license)
                    temporary = fingerprint.with_suffix('.tmp')
                    temporary.write_text(digest + '\n')
                    temporary.chmod(0o600)
                    temporary.replace(fingerprint)
            self.state = 'configure'
        elif self.state == 'configure':
            require('proxy', 'port', str(config.port))
            require('mode', 'proxy')
            require('dns', 'log', 'disable')
            require('tunnel', 'protocol', 'set', config.protocol)
            if config.protocol == 'MASQUE':
                require('tunnel', 'masque-options', 'set', config.masque_options)
            if config.endpoint:
                require('tunnel', 'endpoint', 'set', config.endpoint)
            require('connect')
            self.state = 'monitor'
            self.unhealthy_since = time.monotonic()
        elif self.state == 'monitor':
            for path in STATE_DIR.glob('*.txt'):
                if path.stat().st_size > 10 * 1024 * 1024:
                    os.truncate(path, 0)
            if healthy(config):
                self.unhealthy_since = None
            else:
                now = time.monotonic()
                if self.unhealthy_since is None:
                    self.unhealthy_since = now
                if now - self.unhealthy_since >= config.restart_after_seconds:
                    print('Restarting unhealthy warp-svc', flush=True)
                    self.terminate('warp-svc')
                    self.start('warp-svc')
                elif not connected_or_connecting(cli('status')):
                    if cli('connect').returncode:
                        print('WARP reconnect failed; watchdog remains active', file=sys.stderr, flush=True)

    def serve(self):
        for signum in (signal.SIGTERM, signal.SIGINT):
            signal.signal(signum, self.signal_stop)
        for directory in (*RUNTIME_DIRS, STATE_DIR):
            directory.mkdir(parents=True, exist_ok=True)
            directory.chmod(0o700)
        try:
            self.start('dbus')
            self.start('warp-svc')
            next_step = 0
            while not self.stop.is_set():
                self.reap()
                for name, process in list(self.children.items()):
                    if process.poll() is not None:
                        print(f'{name} exited ({process.returncode}); restarting', flush=True)
                        self.start(name)
                        next_step = 0
                if time.monotonic() >= next_step:
                    previous = self.state
                    try:
                        self.step()
                    except (RuntimeError, OSError) as error:
                        print(f'Retry in {self.state}: {type(error).__name__}', file=sys.stderr, flush=True)
                        self.state = 'ipc'
                    if previous != self.state:
                        print(f'WARP: {previous} -> {self.state}', flush=True)
                    delay = self.config.sleep_seconds if self.state == 'monitor' else 2
                    if previous != self.state:
                        delay = 5 if self.state == 'monitor' else 0
                    next_step = time.monotonic() + delay
                self.stop.wait(1)
        finally:
            self.signal_stop()
            self.terminate('warp-svc')
            self.terminate('dbus')
            self.reap()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--healthcheck', action='store_true')
    args = parser.parse_args()
    try:
        config = Config.from_env()
        if args.healthcheck:
            return 0 if healthy(config) else 1
        Manager(config).serve()
        return 0
    except (ValueError, OSError) as error:
        print(f'WARP startup failed: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())

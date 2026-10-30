"""Deploy files (spec 4): written, never run by the tests."""
import re
import shutil
import subprocess
from pathlib import Path

import pytest

SERVER = Path(__file__).parent.parent
DEPLOY = SERVER / "deploy"
SCRIPTS = [DEPLOY / "install.sh", SERVER / "deploy.sh"]
ALL_FILES = [DEPLOY / n for n in ("myguide.caddy", "Caddyfile.main", "myguide.service", "limits.conf", "install.sh")] + [
    SERVER / "deploy.sh", SERVER / "www" / "index.html", SERVER / "README.md", SERVER / "bin" / "myguide-admin"]


def text(p):
    return p.read_text(encoding="utf-8")


def test_caddy_site_proxies_api_unbuffered_and_serves_the_website():
    t = text(DEPLOY / "myguide.caddy")
    assert "\nmyguide.itsalie.xyz {" in t
    assert "handle /v1/*" in t and "flush_interval -1" in t and "handle /health" in t
    assert "127.0.0.1:8710" in t and "root * /srv/www/myguide" in t and "file_server" in t
    assert not re.search(r"^\s*log\b", t, re.M)


def test_main_caddyfile_only_imports_sites():
    lines = [l.strip() for l in text(DEPLOY / "Caddyfile.main").splitlines() if l.strip() and not l.strip().startswith("#")]
    assert lines == ["import sites/*.caddy"]


def test_placeholder_site_has_no_script_and_no_external_request():
    t = text(SERVER / "www" / "index.html")
    assert "<script" not in t.lower() and "http" not in t.lower()
    assert "MyGuide" in t


def test_unit_hardening_and_layout():
    t = text(DEPLOY / "myguide.service")
    for line in ("User=myguide", "Group=myguide", "WorkingDirectory=/opt/myguide/src", "ProtectSystem=strict",
                 "ReadWritePaths=/srv/myguide", "ProtectHome=yes", "PrivateTmp=yes", "NoNewPrivileges=yes",
                 "Restart=on-failure", "ExecReload=/bin/kill -HUP $MAINPID",
                 "ExecStart=/opt/myguide/venv/bin/python -m myguide --env /etc/myguide/env --db /srv/myguide/guide.db"):
        assert line in t.splitlines(), line
    assert "MemoryMax" not in t and "CPUWeight" not in t


def test_limits_drop_in():
    t = text(DEPLOY / "limits.conf").splitlines()
    assert "[Service]" in t and "MemoryMax=200M" in t and "CPUWeight=50" in t


def test_wrapper_runs_from_the_source_directory_the_unit_uses():
    t = text(SERVER / "bin" / "myguide-admin")
    assert "cd /opt/myguide/src" in t
    assert t.index("cd /opt/myguide/src") < t.index("myguide.admin")


@pytest.mark.parametrize("p", [f for f in ALL_FILES if f.name != "README.md"], ids=lambda p: p.name)
def test_no_file_mentions_the_other_product(p):
    assert "kunngjoring" not in text(p).lower()


def test_only_the_readme_names_the_other_product_and_only_to_check_it():
    t = text(SERVER / "README.md")
    mentions = [l for l in t.splitlines() if "kunngjoring" in l.lower()]
    assert mentions and all("systemctl list-timers" in l for l in mentions)


def test_env_template_holds_no_key():
    t = text(SERVER / "env.template")
    assert "sk-" not in t and re.search(r"^OPENAI_API_KEY=$", t, re.M)


@pytest.mark.parametrize("p", SCRIPTS, ids=lambda p: p.name)
def test_scripts_are_strict_and_valid(p):
    lines = text(p).splitlines()
    assert lines[0].startswith("#!") and "bash" in lines[0]
    assert "set -euo pipefail" in lines[:4]
    assert subprocess.run(["bash", "-n", str(p)]).returncode == 0


@pytest.mark.skipif(shutil.which("shellcheck") is None, reason="shellcheck not installed")
@pytest.mark.parametrize("p", SCRIPTS, ids=lambda p: p.name)
def test_shellcheck(p):
    assert subprocess.run(["shellcheck", str(p)]).returncode == 0


def test_deploy_script_needs_the_go_flag_before_touching_the_network():
    t = text(SERVER / "deploy.sh")
    guard = t.index("MYGUIDE_DEPLOY_GO")
    assert guard < t.index("rsync") and guard < t.index("ssh ")
    assert "--exclude .venv" in t and "--exclude tests" in t and "--delete" in t
    assert "/opt/myguide/src/" in t and "bash /opt/myguide/src/deploy/install.sh" in t


def test_install_keeps_ssh_open_before_enabling_the_firewall():
    t = text(DEPLOY / "install.sh")
    a, b, c, d = (t.index(s) for s in ("ufw allow 22/tcp", "ufw allow 80/tcp", "ufw allow 443/tcp", "ufw --force enable"))
    assert a < d and b < d and c < d
    assert "default deny outgoing" not in t and "ufw deny out" not in t and "ufw reset" not in t


def test_install_never_prints_or_overwrites_the_key():
    t = text(DEPLOY / "install.sh")
    assert "cat /etc/myguide/env" not in t and "OPENAI_API_KEY" in t
    assert "chmod 0640" in t or "install -m 0640" in t

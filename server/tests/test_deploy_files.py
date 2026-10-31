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


def test_main_caddyfile_imports_sites_and_strips_addresses_from_the_log():
    t = text(DEPLOY / "Caddyfile.main")
    body = [l.strip() for l in t.splitlines() if l.strip() and not l.strip().startswith("#")]
    assert body[0] == "{" and body[-1] == "import sites/*.caddy"
    assert "format filter" in t and "wrap json" in t
    for f in ("request>remote_ip", "request>client_ip", "request>remote_port", "request>headers"):
        assert f"{f} delete" in t


def test_placeholder_site_has_no_script_and_no_external_request():
    t = text(SERVER / "www" / "index.html")
    assert "<script" not in t.lower() and "http" not in t.lower()
    assert "MyGuide" in t


def test_unit_hardening_and_layout():
    t = text(DEPLOY / "myguide.service")
    for line in ("User=myguide", "Group=myguide", "WorkingDirectory=/opt/myguide/src", "ProtectSystem=strict",
                 "ReadWritePaths=/srv/myguide", "ProtectHome=yes", "PrivateTmp=yes", "NoNewPrivileges=yes",
                 "Restart=on-failure", "ExecReload=/bin/kill -HUP $MAINPID", "RestartSec=5",
                 "ExecStart=/opt/myguide/venv/bin/python -m myguide --env /etc/myguide/env --db /srv/myguide/guide.db"):
        assert line in t.splitlines(), line
    assert "MemoryMax" not in t and "CPUWeight" not in t


def test_unit_stop_timeout_outlasts_the_longest_call():
    # A stop (deploy, reboot) lets calls in flight finish: a stream may run UPSTREAM_TIMEOUT_SECONDS=120,
    # so systemd waits 150 s (120 + 30 s for settling and shutdown) before it kills the service.
    lines = text(DEPLOY / "myguide.service").splitlines()
    assert "TimeoutStopSec=150" in lines
    template = dict(l.split("=", 1) for l in text(SERVER / "env.template").splitlines() if l and not l.startswith("#"))
    assert 150 > int(template["UPSTREAM_TIMEOUT_SECONDS"])


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
    assert "status --porcelain server" in t and "--chown" not in t and "--files-from" not in t
    assert sum("--delete" in l for l in t.splitlines() if not l.lstrip().startswith("#")) == 1
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


def test_install_exports_needrestart_guards_and_has_one_validated_apply_path():
    t = text(DEPLOY / "install.sh")
    assert "NEEDRESTART_SUSPEND=1" in t and "NEEDRESTART_MODE=l" in t
    assert t.index("NEEDRESTART_SUSPEND=1") < t.index("apt-get install")


# --- the env merge and the Caddy decision, executed under bash ---

INSTALL = DEPLOY / "install.sh"


def run_fn(tmp_path, call, env=None, stub_caddy=None):
    """Source install.sh (its main is guarded) and run `call` with every path inside tmp_path."""
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir(exist_ok=True)
    if stub_caddy is not None:
        stub = bin_dir / "caddy"
        stub.write_text(stub_caddy)
        stub.chmod(0o755)
    e = {"PATH": f"{bin_dir}:/usr/bin:/bin:/usr/sbin:/sbin", "MYGUIDE_TEST_ENV_FILE": str(tmp_path / "env"),
         "MYGUIDE_TEST_CADDY_DIR": str(tmp_path / "caddy"), "HOME": str(tmp_path), **(env or {})}
    return subprocess.run(["bash", "-c", f"source {INSTALL}; {call}"], env=e, capture_output=True, text=True)


def tree(root):
    return {str(p.relative_to(root)): p.read_bytes() for p in sorted(Path(root).rglob("*")) if p.is_file()}


def test_env_is_created_from_the_template_when_missing(tmp_path):
    r = run_fn(tmp_path, f"sync_env {SERVER / 'env.template'}")
    assert r.returncode == 0
    assert (tmp_path / "env").read_text() == text(SERVER / "env.template")


def test_env_merge_keeps_values_appends_missing_and_never_prints_the_key(tmp_path):
    # No trailing newline on the last line, and a changed value and a secret that must survive untouched.
    (tmp_path / "env").write_text("QUOTA_STORY_PER_DAY=7\nOPENAI_API_KEY=sk-secret-value\nLISTEN_PORT=9999")
    r = run_fn(tmp_path, f"sync_env {SERVER / 'env.template'}")
    assert r.returncode == 0
    got = (tmp_path / "env").read_text()
    lines = got.splitlines()
    assert lines[:3] == ["QUOTA_STORY_PER_DAY=7", "OPENAI_API_KEY=sk-secret-value", "LISTEN_PORT=9999"]
    for name in ("CHALLENGES_MAX_OUTSTANDING", "CHALLENGES_PER_IP_PER_HOUR", "ATTEST_MAX_BODY_BYTES", "QUOTA_IMAGE_PER_DAY"):
        assert f"{name}=" in got and name in r.stdout
    assert "OPENAI_API_KEY" not in r.stdout  # present already, so not "added"
    assert "sk-secret-value" not in r.stdout + r.stderr
    assert got.count("QUOTA_STORY_PER_DAY=") == 1 and got.count("LISTEN_PORT=") == 1 and got.count("OPENAI_API_KEY=") == 1
    # Second run changes nothing and prints nothing about additions.
    before = got
    r2 = run_fn(tmp_path, f"sync_env {SERVER / 'env.template'}")
    assert (tmp_path / "env").read_text() == before and "Added" not in r2.stdout


def test_env_merge_reads_a_template_whose_last_line_has_no_newline(tmp_path):
    tpl = tmp_path / "t"
    tpl.write_text("A=1\nB=2")
    (tmp_path / "env").write_text("A=5\n")
    assert run_fn(tmp_path, f"sync_env {tpl}").returncode == 0
    assert (tmp_path / "env").read_text() == "A=5\nB=2\n"


DEBIAN_DEFAULT = ":80 {\n\troot * /usr/share/caddy\n\tfile_server\n}\n"
OK_CADDY = "#!/bin/sh\nexit 0\n"
BAD_CADDY = "#!/bin/sh\necho invalid >&2\nexit 1\n"


def md5(s):
    import hashlib
    return hashlib.md5(s.encode()).hexdigest()


def caddy_dir(tmp_path, content=None):
    d = tmp_path / "caddy"
    d.mkdir()
    if content is not None:
        (d / "Caddyfile").write_text(content)
    return d


def apply(tmp_path, md5_of_default, caddy=OK_CADDY):
    # SRC is the real server/ directory (install.sh derives it from its own location).
    return run_fn(tmp_path, "install_caddy_config", env={"MYGUIDE_TEST_PACKAGED_MD5": md5_of_default}, stub_caddy=caddy)


def test_packaged_default_caddyfile_is_replaced_and_site_installed(tmp_path):
    d = caddy_dir(tmp_path, DEBIAN_DEFAULT)
    r = apply(tmp_path, md5(DEBIAN_DEFAULT))
    assert r.returncode == 0, r.stderr
    assert (d / "Caddyfile").read_text() == text(DEPLOY / "Caddyfile.main")
    assert (d / "sites" / "myguide.caddy").read_text() == text(DEPLOY / "myguide.caddy")


def test_missing_or_empty_caddyfile_gets_ours(tmp_path):
    d = caddy_dir(tmp_path)
    assert apply(tmp_path, "").returncode == 0
    assert (d / "Caddyfile").read_text() == text(DEPLOY / "Caddyfile.main")


def test_default_block_plus_another_site_is_not_the_default_and_is_left_alone(tmp_path):
    # Contains the default's root line but is not byte-identical to the packaged file.
    mine = DEBIAN_DEFAULT + "other.example.com {\n\trespond hi\n}\n"
    d = caddy_dir(tmp_path, mine)
    before = tree(d)
    r = apply(tmp_path, md5(DEBIAN_DEFAULT))
    assert r.returncode != 0 and "import sites/*.caddy" in r.stderr
    assert tree(d) == before


def test_unknown_dpkg_info_means_other_content(tmp_path):
    d = caddy_dir(tmp_path, DEBIAN_DEFAULT)
    before = tree(d)
    assert apply(tmp_path, "").returncode != 0
    assert tree(d) == before


def test_existing_file_that_imports_our_sites_is_kept_and_site_added(tmp_path):
    mine = "{\n\temail me@example.com\n}\nimport sites/*.caddy\n"
    d = caddy_dir(tmp_path, mine)
    (d / "sites").mkdir()
    (d / "sites" / "other.caddy").write_text("other.example.com {\n}\n")
    r = apply(tmp_path, "")
    assert r.returncode == 0, r.stderr
    assert (d / "Caddyfile").read_text() == mine
    assert (d / "sites" / "other.caddy").exists() and (d / "sites" / "myguide.caddy").exists()


def test_validation_failure_leaves_everything_unchanged_and_validates_the_staged_main(tmp_path):
    d = caddy_dir(tmp_path, DEBIAN_DEFAULT)
    before = tree(d)
    r = apply(tmp_path, md5(DEBIAN_DEFAULT), caddy=BAD_CADDY)
    assert r.returncode != 0 and "nothing under" in r.stderr
    assert tree(d) == before and not (d / "sites").exists()


def test_validation_runs_on_a_staged_copy_with_the_new_site_not_on_etc_caddy(tmp_path):
    caddy_dir(tmp_path, DEBIAN_DEFAULT)
    log = tmp_path / "args"
    stub = f'#!/bin/sh\necho "$@" > {log}\ncat "$(dirname "$3")/sites/myguide.caddy" >> {log}\nexit 0\n'
    r = apply(tmp_path, md5(DEBIAN_DEFAULT), caddy=stub)
    assert r.returncode == 0, r.stderr
    first = log.read_text().splitlines()[0]
    assert first.startswith("validate --config ") and "--adapter caddyfile" in first
    assert str(tmp_path / "caddy") not in first and "myguide.itsalie.xyz" in log.read_text()


def test_deploy_script_refuses_without_the_go_flag():
    # Safe to execute: it exits before any git, rsync or ssh call. Never run it with the flag set.
    r = subprocess.run(["bash", str(SERVER / "deploy.sh")], env={"PATH": "/usr/bin:/bin"}, capture_output=True, text=True)
    assert r.returncode == 1 and "MYGUIDE_DEPLOY_GO=1" in r.stderr


def test_main_refuses_when_a_test_override_is_set_before_any_side_effect(tmp_path):
    env = {"PATH": "/usr/bin:/bin", "MYGUIDE_TEST_ENV_FILE": str(tmp_path / "env")}
    r = subprocess.run(["bash", str(INSTALL)], env=env, capture_output=True, text=True)
    assert r.returncode == 1 and "MYGUIDE_TEST_" in r.stderr
    assert not (tmp_path / "env").exists()


def git(cwd, *args):
    subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@t", *args], cwd=cwd, check=True,
                   capture_output=True)


def run_stage(repo, stage):
    return subprocess.run(["bash", "-c", f"source {SERVER / 'deploy.sh'}; build_stage {repo} {stage}"],
                          capture_output=True, text=True, env={"PATH": "/usr/bin:/bin"})


def test_stage_holds_only_tracked_server_files_with_a_readable_root(tmp_path):
    repo, stage = tmp_path / "repo", tmp_path / "stage"
    (repo / "server" / "deploy").mkdir(parents=True)
    (repo / "server" / "myguide").mkdir()
    (repo / "server" / ".venv").mkdir()
    (repo / "other").mkdir()
    (repo / "server" / "deploy" / "install.sh").write_text("#!/bin/bash\n")
    (repo / "server" / "myguide" / "a.py").write_text("x")
    (repo / "server" / "name with space.txt").write_text("s")
    (repo / "other" / "no.txt").write_text("n")
    (repo / "server" / "untracked.txt").write_text("u")
    (repo / "server" / ".venv" / "v.py").write_text("v")
    (repo / ".gitignore").write_text(".venv/\n")
    git(repo, "init", "-q")
    git(repo, "add", "-A")
    git(repo, "rm", "-q", "--cached", "server/untracked.txt")
    git(repo, "commit", "-qm", "x")
    stage.mkdir(mode=0o700)
    r = run_stage(repo, stage)
    assert r.returncode == 0, r.stderr
    assert sorted(tree(stage)) == ["deploy/install.sh", "myguide/a.py", "name with space.txt"]
    assert stage.stat().st_mode & 0o777 == 0o755


def test_stage_without_the_installer_is_refused(tmp_path):
    repo, stage = tmp_path / "repo", tmp_path / "stage"
    (repo / "server").mkdir(parents=True)
    (repo / "server" / "a.txt").write_text("a")
    git(repo, "init", "-q")
    git(repo, "add", "-A")
    git(repo, "commit", "-qm", "x")
    stage.mkdir()
    r = run_stage(repo, stage)
    assert r.returncode == 1 and "install.sh" in r.stderr


def test_caddy_stage_dir_is_removed_on_every_path(tmp_path):
    caddy_dir(tmp_path, DEBIAN_DEFAULT)
    tmpdir = tmp_path / "tmp"
    tmpdir.mkdir()
    for caddy in (OK_CADDY, BAD_CADDY):
        r = run_fn(tmp_path, "install_caddy_config || true",
                   env={"MYGUIDE_TEST_PACKAGED_MD5": md5(DEBIAN_DEFAULT), "TMPDIR": str(tmpdir)}, stub_caddy=caddy)
        assert r.returncode == 0 and list(tmpdir.iterdir()) == []

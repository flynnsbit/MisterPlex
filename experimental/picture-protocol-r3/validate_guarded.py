#!/usr/bin/env python3
from __future__ import annotations
from contextlib import ExitStack
from pathlib import Path
import datetime
import hashlib
import importlib.util
import json
import os
import subprocess
import sys

ROOT = Path('/home/flynnsbit/Projects/MisterPlex')
WT = ROOT / '.worktrees/fpga-h264-fleet-30ff2997'
PROJECT = WT / 'build/fpga-picture-functional-r3-5754/project'
OUT = WT / 'build/fpga-picture-functional-r3-5754/validation'
GUARD = WT / 'build/coherent-v15-physical-5754/staged/timing-tool-r4/source/scripts/rbf_build.py'
GUARD_SHA = '0be637ccb53ecb6bd1335b53bec7bdef1a87bbb8671c3e1c055172ca32441e16'
OWNER = '5754832e-26fa-4cbe-8556-2be7e828bb95'
GRANT = 'replace-picture-ownership-protocol-r3-5754'


def now() -> str:
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def save(path: Path, data) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + '\n')


def birth(pid: int) -> int:
    raw = Path(f'/proc/{pid}/stat').read_text().rsplit(') ', 1)[1].split()
    return int(raw[19])


def descriptor(fd: int):
    info = os.fstat(fd)
    lines = Path(f'/proc/self/fdinfo/{fd}').read_text().splitlines()
    locks = [line for line in lines if line.startswith('lock:')]
    if not locks:
        raise RuntimeError('inherited descriptor has no actual kernel lock')
    return {'fd': fd, 'device': info.st_dev, 'inode': info.st_ino, 'kernel_locks': locks}


def file_manifest(paths: list[Path]):
    items = {}
    for path in paths:
        data = path.read_bytes()
        items[str(path.relative_to(PROJECT))] = {
            'sha256': hashlib.sha256(data).hexdigest(),
            'mode': oct(path.stat().st_mode & 0o777),
            'bytes': len(data),
        }
    return items


def main() -> int:
    plan_only = len(sys.argv) > 1 and sys.argv[1] == '--plan'
    if plan_only:
        sys.argv.pop(1)
    if len(sys.argv) < 3:
        print('usage: validate_guarded.py CAMPAIGN command [args...]', file=sys.stderr)
        return 2
    campaign_name = sys.argv[1]
    command = sys.argv[2:]
    campaign = OUT / campaign_name
    campaign.mkdir(parents=True, exist_ok=True)
    tracked = sorted(path for path in PROJECT.rglob('*') if path.is_file() and
                     not {'build', '__pycache__'}.intersection(path.relative_to(PROJECT).parts))
    reference = os.environ.get('MPX_REJECTED_R2_RTL')
    reference_pin = None
    if reference:
        reference_path = Path(reference).resolve(strict=True)
        reference_pin = {
            'path': str(reference_path),
            'sha256': hashlib.sha256(reference_path.read_bytes()).hexdigest(),
            'mode': oct(reference_path.stat().st_mode & 0o777),
        }
    save(campaign / ('plan.json' if plan_only else 'intent.json'), {
        'owner': OWNER,
        'grant': GRANT,
        'entered_utc': now(),
        'cwd': str(PROJECT),
        'command': command,
        'guard_source': str(GUARD),
        'guard_source_sha256': GUARD_SHA,
        'tracked_inputs': file_manifest(tracked),
        'rejected_reference': reference_pin,
    })
    if plan_only:
        return 0
    if hashlib.sha256(GUARD.read_bytes()).hexdigest() != GUARD_SHA:
        raise RuntimeError('existing shared guard source pin changed')
    spec = importlib.util.spec_from_file_location('mpx_existing_guards', GUARD)
    guard = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(guard)
    inherited = descriptor(9)
    expected = (ROOT / 'build/resource-preflight.lock').stat()
    if (inherited['device'], inherited['inode']) != (expected.st_dev, expected.st_ino):
        raise RuntimeError('not holding the actual primary heavy-validation lock')
    pid = os.getpid()
    ownership = {
        'owner': OWNER,
        'grant': GRANT,
        'pid': pid,
        'birth': birth(pid),
        'entered_utc': now(),
        'heavy_validation': inherited,
        'guard_source_sha256': GUARD_SHA,
        'acquired': False,
    }
    save(campaign / 'guard-entry.json', ownership)
    try:
        with ExitStack() as stack:
            controller = stack.enter_context(guard.host_lock(guard.CONTROLLER_KEY))
            repo_paths = sorted({guard.repository_lock(ROOT), guard.repository_lock(WT)})
            repositories = [stack.enter_context(guard.fit_lock(path)) for path in repo_paths]
            execution = stack.enter_context(guard.host_lock(guard.EXECUTION_KEY))
            semaphores = []
            for key in (guard.CONTROLLER_KEY, guard.EXECUTION_KEY):
                sem = guard.LIBC.semget(key, 1, 0o666)
                value = guard.LIBC.semctl(sem, 0, 12, 0)
                owner_pid = guard.LIBC.semctl(sem, 0, 11, 0)
                if sem < 0 or value != 0 or owner_pid != pid:
                    raise RuntimeError('actual semaphore ownership does not match this process')
                semaphores.append({'key': key, 'semid': sem, 'value': value, 'last_operation_pid': owner_pid})
            ownership.update(
                acquired=True,
                acquired_utc=now(),
                semaphores=semaphores,
                repository_locks=[{'path': str(path), **descriptor(lease.fd)} for path, lease in zip(repo_paths, repositories)],
                tracked_inputs_before=file_manifest(tracked),
            )
            save(campaign / 'guard-acquired.json', ownership)
            leases = [controller, *repositories, execution]
            controller.owner = campaign / 'controller-owner.local.json'
            execution.owner = campaign / 'execution-owner.local.json'
            for lease in leases:
                lease.retain('owned guarded FPGA functional R3 validation running; release only after child settlement')
            environment = dict(os.environ)
            environment['MPX_KEEP_TEST_WORK'] = '1'
            environment['PYTHONDONTWRITEBYTECODE'] = '1'
            child = None
            try:
                with (campaign / 'command.log').open('w') as output:
                    child = subprocess.Popen(command, cwd=PROJECT, env=environment,
                                             stdout=output, stderr=subprocess.STDOUT,
                                             pass_fds=(9, *(lease.fd for lease in repositories)))
                    save(campaign / 'child.json', {
                        'owner': OWNER,
                        'grant': GRANT,
                        'pid': child.pid,
                        'birth': birth(child.pid),
                        'started_utc': now(),
                        'cwd': str(PROJECT),
                        'command': command,
                    })
                    result = child.wait()
            finally:
                if child is None or child.poll() is not None:
                    for lease in leases:
                        lease.confirmed()
            inputs_after = file_manifest(tracked)
            reference_after = None if not reference else hashlib.sha256(reference_path.read_bytes()).hexdigest()
            save(campaign / 'child-result.json', {
                'owner': OWNER,
                'grant': GRANT,
                'finished_utc': now(),
                'exit_code': result,
                'pid': None if child is None else child.pid,
                'child_reaped': False if child is None else child.poll() is not None,
                'tracked_inputs_after': inputs_after,
                'reference_sha256_after': reference_after,
            })
        ownership.update(released=True, released_utc=now())
        ownership['released_semaphore_values'] = [
            {'key': item['key'], 'semid': item['semid'],
             'value_observed_after_release': guard.LIBC.semctl(item['semid'], 0, 12, 0)}
            for item in ownership['semaphores']
        ]
        save(campaign / 'guard-released.json', ownership)
        if ownership['tracked_inputs_before'] != inputs_after:
            raise RuntimeError('validation changed tracked source inputs')
        if reference_pin is not None and reference_pin['sha256'] != reference_after:
            raise RuntimeError('validation changed the frozen reference input')
        print(f'guarded validation completed rc={result} campaign={campaign_name}')
        return result
    except Exception as error:
        save(campaign / 'failure.json', {
            'owner': OWNER,
            'grant': GRANT,
            'at': now(),
            'error': str(error),
            'guard_acquisition_record': ownership,
        })
        raise


if __name__ == '__main__':
    raise SystemExit(main())

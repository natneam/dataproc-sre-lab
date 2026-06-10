import subprocess

result = subprocess.run(
    ['yarn', 'application', '-list', '-appStates', 'RUNNING,ACCEPTED'],
    capture_output=True, text=True
)
print(result.stdout)

app_ids = [
    line.split()[0]
    for line in result.stdout.splitlines()
    if line.startswith('application_') and 'queue-flood' in line
]

print(f"Found {len(app_ids)} queue-flood apps to kill: {app_ids}")
for app_id in app_ids:
    r = subprocess.run(['yarn', 'application', '-kill', app_id], capture_output=True, text=True)
    print(f"  {app_id}: {r.stdout.strip() or r.stderr.strip()}")

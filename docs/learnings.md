# Ansible SSM Debugging Learnings

## Problem

`aws ssm start-session` worked, instances were `Online` in Systems Manager, and `send-command` worked, but:

```bash
ansible all -m ansible.builtin.ping
```

hung indefinitely on the control machine.

## What Was Working

- EC2 instances were running.
- Systems Manager showed all instances as `Online`.
- `aws ssm start-session` connected successfully.
- Direct boto3 `start_session()` worked.
- The S3 bucket used by the Ansible SSM transport was reachable.
- Remote hosts had `curl` and `python3`.
- Ansible dynamic inventory loaded successfully.

## What We Tried

- Confirmed SSM health with `aws ssm start-session` and `send-command`.
- Confirmed S3 access with `aws s3api head-bucket`.
- Tested one host at a time with `-l <instance-id>` and `-f 1`.
- Forced `AWS_PROFILE`, disabled IMDS lookup, and reduced timeouts.
- Removed misleading `remote_user` usage for `aws_ssm`.
- Pinned `amazon.aws` and tested in a clean Python 3.13 virtualenv.
- Instrumented the local `amazon.aws` collection to see exactly where it stalled.

## Key Finding

The hang was not on the EC2 instance or in SSM itself. It occurred on the macOS control machine inside Ansible's `amazon.aws.aws_ssm` connection plugin while initializing the S3 boto3 client used by the SSM transport.

In other words:

- plain AWS CLI SSM worked
- plain boto3 SSM worked
- Ansible over `aws_ssm` on macOS did not

## Working Solution

Run Ansible from a Linux Docker container instead of directly on macOS.

Commands:

```bash
cd aws-autoscale-stack/ansible
docker build --no-cache -f Dockerfile.ansible -t capstone-ansible:ssm .
./with-docker-ansible.sh ansible all -m ansible.builtin.ping -f 1
./with-docker-ansible.sh ansible-playbook site.yml
```

## Follow-up Fixes

After the Docker controller was working, two playbook issues also had to be corrected:

- `group_vars/all/vars.yml` used the `json_query` filter to read `inventory/tf_outputs.json`. The Docker image did not include that filter dependency, so the lookups were changed to direct dictionary access.
- `roles/db_init/tasks/main.yml` tried to install `mariadb`, which was not available on Amazon Linux 2023. This was updated to `mariadb105`.

## End-to-End Verification

The final deployment was verified successfully:

- `ansible all -m ansible.builtin.ping -f 1` worked through the Docker wrapper.
- `ansible-playbook site.yml` completed successfully.
- `vault.yml` could be used with `ansible-vault` through the Docker wrapper.
- The Flask app responded correctly through the ALB DNS name.
- The Nginx public IP served the frontend and proxied API requests correctly.
- `/health` and `/items` worked from both `nginx_public_ip` and `alb_dns_name`.
- The `/items` response confirmed that database seeding had completed successfully.

Useful verification commands:

```bash
./with-docker-ansible.sh ansible all -m ansible.builtin.ping -f 1
./with-docker-ansible.sh ansible-playbook site.yml --ask-vault-pass
curl http://<alb_dns_name>/health
curl http://<alb_dns_name>/items
curl http://<nginx_public_ip>/api/health
curl http://<nginx_public_ip>/api/items
```

## Important Docker Detail

The Session Manager plugin path inside the container is:

```bash
/usr/local/sessionmanagerplugin/bin/session-manager-plugin
```

The wrapper script exports that path automatically, so the Ansible vars file should not hardcode a host-specific plugin path.

## Report-Friendly Conclusion

The root issue was a controller-side compatibility problem with Ansible's AWS SSM connection path on macOS, not an AWS infrastructure or IAM configuration failure. The final workaround was to move the Ansible control node into a Linux container, where the same inventory and AWS setup worked correctly.

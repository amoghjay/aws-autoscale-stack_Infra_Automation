# Troubleshooting Learnings

## 1. Ansible over SSM on macOS was the first blocker

### Symptom

The instances were healthy in AWS, but:

```bash
ansible all -m ansible.builtin.ping
```

hung on the control machine.

### What was already working

- All EC2 instances were running.
- All instances were `Online` in Systems Manager.
- `aws ssm start-session` worked.
- `aws ssm send-command` worked.
- The S3 bucket used by the Ansible SSM transport was reachable.
- boto3 `start_session()` worked directly.

### What we tried

- Tested one host at a time with `-l <instance-id>` and `-f 1`.
- Forced AWS profile and disabled IMDS lookup.
- Verified S3 access with `aws s3api head-bucket`.
- Checked `curl` and `python3` on the instances.
- Tried different Ansible collection versions.
- Instrumented the Ansible AWS SSM connection plugin.

### What we found

The problem was not AWS, IAM, SSM Agent, or the EC2 instances. The hang was on the macOS control machine inside Ansible's `amazon.aws.aws_ssm` connection flow.

### Final fix

We moved the Ansible controller into Docker and ran Ansible from Linux instead of directly on macOS.

That solved the controller-side compatibility issue while keeping the same AWS inventory and SSM-based access model.

## 2. Docker Ansible uncovered two playbook issues

Once Ansible itself worked through Docker, the playbook exposed two separate repo issues:

### `json_query` filter problem

`group_vars/all/vars.yml` used `json_query` to read `inventory/tf_outputs.json`.

That failed in the Docker-based controller, so the lookups were changed to direct dictionary access.

### MySQL client package problem

The DB init role tried to install `mariadb`, which was not available on Amazon Linux 2023.

It was changed to `mariadb105`.

## 3. End-to-end app deployment worked before autoscaling validation

After those fixes:

- `ansible all -m ansible.builtin.ping -f 1` worked
- `ansible-playbook site.yml` worked
- the app responded through the ALB
- the app responded through Nginx
- `/health` and `/items` both worked
- database seeding succeeded

At that point, the basic infrastructure and configuration path were correct.

## 4. First scaling test showed a design gap

### What we expected

When the ASG scaled out, new app instances should join the target group and become healthy automatically.

### What actually happened

The ASG did scale out, but the new instances were unhealthy and entered a replacement loop.

That exposed a key design problem:

- Ansible was only configuring the instances that existed when `site.yml` was run manually.
- New ASG app instances did not automatically get the Flask app, systemd unit, or related configuration.

So the stack could scale infrastructure, but not reliably scale configured application instances.

## 5. Why DB seeding was not the right thing to put in scale-out bootstrap

We reviewed the seeding flow in:

- [site.yml](/Users/amoghjay/Desktop/Capstone_PRJ/aws-autoscale-stack/ansible/site.yml:1)
- [roles/db_init/tasks/main.yml](/Users/amoghjay/Desktop/Capstone_PRJ/aws-autoscale-stack/ansible/roles/db_init/tasks/main.yml:1)
- [roles/db_init/files/seed.sql](/Users/amoghjay/Desktop/Capstone_PRJ/aws-autoscale-stack/ansible/roles/db_init/files/seed.sql:1)

Findings:

- `db_init` is a separate play
- it uses `run_once: true`
- `seed.sql` uses `CREATE TABLE IF NOT EXISTS`
- inserts are `INSERT IGNORE`

That means rerunning the playbook does not duplicate the seed data, and it also means DB seeding should stay a central, one-time Ansible task, not part of app instance scale-out.

Scaled app instances should only run the `app` role.

## 6. First attempt: `ansible-pull`

### Idea

We first tried using `ansible-pull` in the app launch template so each new app instance could configure itself at boot.

### What changed

We updated the app launch template to:

- install Ansible and boto3
- discover the RDS endpoint at boot
- clone the repo
- run an Ansible bootstrap playbook

### Problems found

This approach exposed multiple issues in sequence:

#### Problem 1: `user_data` script formatting

Cloud-init showed:

- `Exec format error. Missing #! in script?`

Root cause:

- the rendered `user_data` script was not starting cleanly with the shebang

Fix:

- corrected the Terraform heredoc rendering so the bootstrap shell script was valid

#### Problem 2: missing bootstrap playbook in GitHub

The instance cloned the repo from GitHub, but the bootstrap playbook existed only locally and had not been pushed.

That meant:

- the instance successfully cloned the repo
- but failed because `ansible/bootstrap-app.yml` was not present in the remote repo

#### Problem 3: repo Ansible config was wrong for localhost bootstrap

Even after bypassing the missing file, local bootstrap still failed because the repo's Ansible config and group vars were intended for controller-side SSM runs.

Important finding from [group_vars/all/vars.yml](/Users/amoghjay/Desktop/Capstone_PRJ/aws-autoscale-stack/ansible/group_vars/all/vars.yml:1):

- `ansible_connection: amazon.aws.aws_ssm`

That is correct for running Ansible from the control node to remote instances, but wrong for running Ansible locally on the EC2 instance itself.

So a bootstrap playbook inside the repo's `ansible/` tree inherited the wrong connection assumptions.

## 7. Final bootstrap design

The clean solution was:

- stop using `ansible-pull`
- keep using the repo for the real `app` role code
- run a tiny local bootstrap playbook on the instance with `ansible-playbook`

### Final app boot flow

The app launch template now:

1. installs `python3`, `pip`, `git`, `ansible-core`, `boto3`, and `botocore`
2. looks up the RDS endpoint with boto3
3. writes app vars to `/etc/aws-autoscale-stack/app-vars.yml`
4. clones the Git repo to `/opt/aws-autoscale-stack`
5. writes a small local bootstrap playbook to `/etc/aws-autoscale-stack/bootstrap-app.yml`
6. writes a small local Ansible config to `/etc/aws-autoscale-stack/bootstrap-ansible.cfg`
7. runs local `ansible-playbook` on `localhost`

The local config only points to:

- `roles_path = /opt/aws-autoscale-stack/ansible/roles`

This avoids loading the repo inventory and SSM connection settings.

### Why this was better than `ansible-pull`

- no dependence on a remote bootstrap playbook existing in GitHub
- no accidental inheritance of `aws_ssm` connection settings
- still reuses the real Ansible `app` role
- still satisfies the goal of Ansible-based application configuration

### How new app instances are configured

The final model for scaled app instances is:

- Git provides the application configuration code
- Ansible performs the actual application setup
- `user_data` only bootstraps enough for Ansible to run locally

In practice, when a new app instance is launched by the ASG:

1. the instance installs the required tools
2. it discovers the current RDS endpoint
3. it clones the Git repository locally
4. it writes a tiny local bootstrap playbook and local Ansible config
5. it runs `ansible-playbook` on `localhost`
6. that local playbook applies the existing `app` role
7. the `app` role installs dependencies, deploys the Flask app, creates the systemd service, and starts it

This means the shell bootstrap does not hardcode the full app deployment. The actual app configuration still happens through Ansible, while Git is used to supply the Ansible role code to new instances.

## 8. How we proved the new bootstrap worked

We manually tested the final localhost-only bootstrap on an unhealthy `v3` app instance through SSM.

The manual run succeeded:

- the `app` role completed
- `flask.service` was created
- Flask started successfully

Then we verified:

- the repaired instance became `healthy` in the target group
- both app instances were healthy at the same time
- ALB `/health` returned `200 OK`
- ALB `/items` returned the seeded items
- local instance `127.0.0.1:5000/health` returned `200 OK`
- local instance `127.0.0.1:5000/items` returned `200 OK`

That proved the new bootstrap model was valid before applying it broadly.

## 9. Safer validation than waiting for a scale-out event

After stabilizing the environment, we used a cleaner validation method than waiting for a high-load scale-out event:

- we replaced one healthy old app instance at a time
- the other healthy app instance remained in service
- the ASG launched a fresh replacement from the latest launch template
- we watched the replacement move through registration to `healthy`

### What this taught us

- the new bootstrap path works without manual intervention
- a replacement instance can configure itself and become healthy on its own
- the app tier remains available during rolling replacement
- the first health or SSM check can be too early, because bootstrap is asynchronous

In one test:

- the first SSM check ran too soon and `flask.service` was not visible yet
- after a short wait, the replacement instance completed bootstrap and became `healthy`

That was an important finding:

- the right success criterion is not "is the instance instantly ready?"
- the right success criterion is "does the replacement instance become healthy on its own after bootstrapping?"

This one-at-a-time replacement method is a safer validation pattern than discovering bootstrap problems for the first time during a full load-based scale-out event.

## 10. Terraform cleanup for a TA-friendly demo

After stabilizing the app tier, the remaining Terraform noise was caused by image drift.

The original config used the latest Amazon Linux 2023 AMI from SSM, which meant:

- `terraform plan` kept detecting AMI changes over time
- the Nginx instance wanted replacement unexpectedly

### Final cleanup

We pinned tested AMI IDs in Terraform:

- app ASG AMI pinned to the working app instance generation
- Nginx AMI pinned to the current working frontend instance

That made the final Terraform plan much cleaner and more reproducible.

## 11. Scaling policy tuning and final demo behavior

### First autoscaling policy behavior

The initial autoscaling approach used target tracking based on average CPU utilization.

That policy did scale out successfully, but it was not ideal for demonstration:

- it could jump capacity more aggressively than expected
- scale-in behavior was slower and less predictable
- it was harder to explain clearly in a live demo

### Why we changed it

For the capstone demonstration, the goal was not just that autoscaling worked, but that it could be shown clearly and explained simply.

We therefore changed the ASG policy from target tracking to explicit alarm-based simple scaling:

- scale out by `+1`
- scale in by `-1`

### Final scaling policy design

We replaced target tracking with:

- a high CPU CloudWatch alarm
- a low CPU CloudWatch alarm
- a scale-out simple scaling policy
- a scale-in simple scaling policy

Final thresholds:

- scale out when average CPU is above `20%`
- scale in when average CPU is below `10%`
- CloudWatch period: `60s`
- scale-out evaluation periods: `2`
- scale-in evaluation periods: `3`
- cooldown: `180s`

### Why those numbers were chosen

They were chosen from observed CloudWatch behavior during real tests:

- under sustained load, the app tier clearly exceeded `20%` average CPU
- after the load test stopped, the CPU dropped near idle

So these thresholds were based on observed metrics, not arbitrary guesses.

### IAM learning from this change

Switching to CloudWatch-alarm-based scaling required extra permissions that were not originally present on the project admin user.

Missing permissions included:

- `cloudwatch:PutMetricAlarm`
- `cloudwatch:DeleteAlarms`
- `cloudwatch:DescribeAlarms`
- `cloudwatch:ListTagsForResource`
- `cloudwatch:TagResource`
- `cloudwatch:UntagResource`

Additional IAM/SSM permissions were also added to better match the real Terraform and debugging workflow:

- `iam:GetRolePolicy`
- `iam:PutRolePolicy`
- `iam:DeleteRolePolicy`
- `ssm:ListCommands`
- `ssm:ListCommandInvocations`

### Final result of the alarm-based scaling demo

With the new scaling model:

- the ASG scaled out in clearer step-based increments
- load testing showed capacity increasing up to 5 instances during the final demo run
- scale-out behavior was easier to observe and explain
- low CPU alarm behavior after the test matched the intended scale-in trigger conditions

This was a better fit for demonstration than the earlier target-tracking behavior.

## 12. Final operating model

### Controller-side configuration

Run Ansible from Docker using SSM:

```bash
cd aws-autoscale-stack/ansible
./with-docker-ansible.sh ansible all -m ansible.builtin.ping -f 1
./with-docker-ansible.sh ansible-playbook site.yml --ask-vault-pass
```

### App scale-out behavior

New ASG app instances now self-bootstrap at launch by:

- cloning the repo
- writing local bootstrap files
- applying the existing `app` role locally

### DB seed behavior

Database seeding remains:

- central
- manual via `site.yml`
- `run_once`
- outside the scale-out path

That is the correct separation of concerns.

## 13. Final conclusion

The autoscaling issue was not that AWS could not scale. The real issue was that new ASG instances were not receiving application configuration automatically.

The final solution was to separate two concerns clearly:

- use Docker-based Ansible over SSM from the control machine for normal configuration management
- use a lightweight local Ansible bootstrap on new app instances so scaled instances can configure themselves at boot

This produced a stable final state:

- Terraform applies cleanly
- Ansible works
- app paths work through both ALB and Nginx
- database seeding is safe and kept out of scale-out
- new app instances can become healthy without manual intervention
- scaling behavior can be demonstrated more clearly with explicit alarm-based `+1 / -1` policies

## 14. Useful verification commands

```bash
./with-docker-ansible.sh ansible all -m ansible.builtin.ping -f 1
./with-docker-ansible.sh ansible-playbook site.yml --ask-vault-pass
curl http://<alb_dns_name>/health
curl http://<alb_dns_name>/items
curl http://<nginx_public_ip>/api/health
curl http://<nginx_public_ip>/api/items
aws elbv2 describe-target-health --target-group-arn <target-group-arn> --region us-east-1
aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names aws-autoscale-stack-asg --region us-east-1
```

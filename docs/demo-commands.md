# Demo Commands

Use this file as the live demo runbook.

## 1. Terraform

From the Terraform directory:

```bash
cd /Users/amoghjay/Desktop/Capstone_PRJ/aws-autoscale-stack/terraform
terraform plan
terraform apply
terraform output -json > ../ansible/inventory/tf_outputs.json
```

Useful proof commands:

```bash
terraform state show module.asg.aws_autoscaling_group.app
terraform state show module.asg.aws_launch_template.app
```

## 2. Ansible

From the Ansible directory:

```bash
cd /Users/amoghjay/Desktop/Capstone_PRJ/aws-autoscale-stack/ansible
./with-docker-ansible.sh ansible-inventory -i inventory/aws_ec2.yml --graph
./with-docker-ansible.sh ansible all -m ansible.builtin.ping -f 1
./with-docker-ansible.sh ansible-playbook site.yml --ask-vault-pass
```

## 3. Read Terraform Outputs

From the Ansible directory:

```bash
ALB=$(python3 -c "import json; print(json.load(open('inventory/tf_outputs.json'))['alb_dns_name']['value'])")
NGINX=$(python3 -c "import json; print(json.load(open('inventory/tf_outputs.json'))['nginx_public_ip']['value'])")
echo "$ALB"
echo "$NGINX"
```

## 4. App Verification

From the Ansible directory:

```bash
curl -i "http://$ALB/health"
curl -i "http://$ALB/items"
curl -i "http://$NGINX/api/health"
curl -i "http://$NGINX/api/items"
```

## 5. Health Checks From AWS CLI

From anywhere:

```bash
aws elbv2 describe-target-health \
  --target-group-arn $(python3 -c "import json; print(json.load(open('/Users/amoghjay/Desktop/Capstone_PRJ/aws-autoscale-stack/ansible/inventory/tf_outputs.json'))['alb_target_group_arn']['value'])") \
  --region us-east-1 \
  --query 'TargetHealthDescriptions[*].{Instance:Target.Id,State:TargetHealth.State,Reason:TargetHealth.Reason}' \
  --output table
```

```bash
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names aws-autoscale-stack-asg \
  --region us-east-1 \
  --query 'AutoScalingGroups[0].Instances[*].{Id:InstanceId,State:LifecycleState,Health:HealthStatus,Version:LaunchTemplate.Version}' \
  --output table
```

## 6. CloudWatch / Scaling Demo

Open these in AWS Console before running the test:

- `CloudWatch -> Metrics -> EC2 -> By Auto Scaling Group -> CPUUtilization`
- `CloudWatch -> Metrics -> Auto Scaling -> By Auto Scaling Group`
- `CloudWatch -> Alarms -> All alarms`
- `EC2 -> Auto Scaling Groups -> aws-autoscale-stack-asg -> Activity`
- `EC2 -> Auto Scaling Groups -> aws-autoscale-stack-asg -> Instance management`
- `EC2 -> Target Groups -> aws-autoscale-stack-flask-tg -> Targets`

Recommended Auto Scaling metrics to graph:

- `GroupDesiredCapacity`
- `GroupInServiceInstances`
- `GroupPendingInstances`
- `GroupTerminatingInstances`
- `GroupTotalInstances`

Expected alarms:

- `aws-autoscale-stack-cpu-high`
- `aws-autoscale-stack-cpu-low`

## 7. Evidence Collection

From the repo root, in Terminal 1:

```bash
cd /Users/amoghjay/Desktop/Capstone_PRJ/aws-autoscale-stack
mkdir -p evidence
bash scripts/collect_evidence.sh --duration 1200 --interval 30
```

## 8. Load Test

From the repo root, in Terminal 2:

```bash
cd /Users/amoghjay/Desktop/Capstone_PRJ/aws-autoscale-stack
ALB=$(python3 -c "import json; print(json.load(open('ansible/inventory/tf_outputs.json'))['alb_dns_name']['value'])")

python3 scripts/load_test.py \
  --url "http://$ALB/items" \
  --workers 200 \
  --duration 600 \
  --progress-interval 15 \
  --output evidence/load_test_results_step_scaling_final.json
```

## 9. What To Capture During Demo

Screenshots to take:

- Terraform `plan`
- Terraform `apply`
- Ansible `ping`
- Ansible `PLAY RECAP`
- ALB `/health`
- ALB `/items`
- Nginx `/api/health`
- Nginx `/api/items`
- `CPUUtilization`
- `GroupDesiredCapacity`
- `GroupInServiceInstances`
- `aws-autoscale-stack-cpu-high` alarm
- `aws-autoscale-stack-cpu-low` alarm
- ASG Activity
- Target group health

## 10. Optional Cleanup

When finished:

```bash
cd /Users/amoghjay/Desktop/Capstone_PRJ/aws-autoscale-stack/terraform
terraform destroy
```

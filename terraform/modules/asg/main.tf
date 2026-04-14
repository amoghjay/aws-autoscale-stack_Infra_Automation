# Security group for Flask app instances (private)
resource "aws_security_group" "app_sg" {
  name        = "${var.project_name}-app-sg"
  description = "Allow Flask traffic from ALB only"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = 5000
    to_port         = 5000
    protocol        = "tcp"
    security_groups = [var.alb_sg_id]
  }


  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-app-sg"
  }
}

# Security group for Nginx (public-facing)
resource "aws_security_group" "nginx_sg" {
  name        = "${var.project_name}-nginx-sg"
  description = "Allow HTTP/HTTPS and SSH inbound to Nginx"
  vpc_id      = var.vpc_id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }


  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-nginx-sg"
  }
}

# IAM instance profile for SSM (optional but useful for debugging)
resource "aws_iam_role" "ec2_ssm_role" {
  name = "${var.project_name}-ec2-ssm-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_policy" {
  role       = aws_iam_role.ec2_ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "ssm_s3_transport" {
  name = "${var.project_name}-ssm-s3-transport"
  role = aws_iam_role.ec2_ssm_role.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:ListBucket",
          "s3:DeleteObject"
        ]
        Resource = [
          "arn:aws:s3:::${var.ssm_s3_bucket}",
          "arn:aws:s3:::${var.ssm_s3_bucket}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "rds:DescribeDBInstances"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "${var.project_name}-ec2-profile"
  role = aws_iam_role.ec2_ssm_role.name
}

# Launch template for ASG
resource "aws_launch_template" "app" {
  name_prefix   = "${var.project_name}-lt-"
  image_id      = var.app_ami_id
  instance_type = "t3.micro"

  iam_instance_profile {
    name = aws_iam_instance_profile.ec2_profile.name
  }

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [aws_security_group.app_sg.id]
  }

  user_data = base64encode(trimspace(<<-EOF
    #!/bin/bash
    set -euxo pipefail

    exec > >(tee /var/log/app-bootstrap.log | logger -t app-bootstrap -s 2>/dev/console) 2>&1

    dnf update -y
    dnf install -y python3 python3-pip git
    pip3 install ansible-core boto3 botocore

    mkdir -p /etc/aws-autoscale-stack

    DB_HOST="$(python3 - <<'PY'
import time
import boto3

client = boto3.client("rds", region_name="${var.aws_region}")
for _ in range(60):
    response = client.describe_db_instances(DBInstanceIdentifier="${var.project_name}-mysql")
    endpoint = response["DBInstances"][0].get("Endpoint", {}).get("Address")
    if endpoint:
        print(endpoint)
        break
    time.sleep(10)
else:
    raise SystemExit("Timed out waiting for RDS endpoint")
PY
)"

    cat >/etc/aws-autoscale-stack/app-vars.yml <<APPVARS
db_host: "$DB_HOST"
db_user: "${var.db_username}"
db_pass: "${var.db_password}"
db_name: "appdb"
flask_port: 5000
APPVARS

    git clone --depth 1 --branch "${var.app_bootstrap_repo_ref}" "${var.app_bootstrap_repo_url}" /opt/aws-autoscale-stack

    cat >/etc/aws-autoscale-stack/bootstrap-app.yml <<'PLAYBOOK'
---
- name: Bootstrap app instance locally
  hosts: localhost
  connection: local
  become: true
  vars_files:
    - /etc/aws-autoscale-stack/app-vars.yml
  roles:
    - app
PLAYBOOK

    cat >/etc/aws-autoscale-stack/bootstrap-ansible.cfg <<'ANSIBLECFG'
[defaults]
roles_path = /opt/aws-autoscale-stack/ansible/roles
host_key_checking = False
ANSIBLECFG

    ANSIBLE_CONFIG=/etc/aws-autoscale-stack/bootstrap-ansible.cfg ansible-playbook -i localhost, -c local /etc/aws-autoscale-stack/bootstrap-app.yml
EOF
  ))

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${var.project_name}-app"
      Role = "app"
    }
  }
}

# Auto Scaling Group
resource "aws_autoscaling_group" "app" {
  name                      = "${var.project_name}-asg"
  min_size                  = 2
  max_size                  = 6
  desired_capacity          = 2
  vpc_zone_identifier       = var.private_subnet_ids
  target_group_arns         = [var.alb_target_group_arn]
  health_check_type         = "ELB"
  health_check_grace_period = 300
  metrics_granularity       = "1Minute"
  enabled_metrics = [
    "GroupDesiredCapacity",
    "GroupInServiceInstances",
    "GroupPendingInstances",
    "GroupTerminatingInstances",
    "GroupTotalInstances",
  ]

  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "${var.project_name}-app"
    propagate_at_launch = true
  }

  tag {
    key                 = "Role"
    value               = "app"
    propagate_at_launch = true
  }
}

# Simple demo-friendly scaling: add 1 instance when ASG average CPU is high,
# remove 1 instance when it stays low for long enough.
resource "aws_autoscaling_policy" "scale_out" {
  name                   = "${var.project_name}-scale-out"
  autoscaling_group_name = aws_autoscaling_group.app.name
  policy_type            = "SimpleScaling"
  adjustment_type        = "ChangeInCapacity"
  scaling_adjustment     = 1
  cooldown               = 180
}

resource "aws_autoscaling_policy" "scale_in" {
  name                   = "${var.project_name}-scale-in"
  autoscaling_group_name = aws_autoscaling_group.app.name
  policy_type            = "SimpleScaling"
  adjustment_type        = "ChangeInCapacity"
  scaling_adjustment     = -1
  cooldown               = 180
}

resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "${var.project_name}-cpu-high"
  alarm_description   = "Scale out by 1 when ASG average CPU stays above 20%"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Average"
  threshold           = 20
  alarm_actions       = [aws_autoscaling_policy.scale_out.arn]

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.app.name
  }
}

resource "aws_cloudwatch_metric_alarm" "cpu_low" {
  alarm_name          = "${var.project_name}-cpu-low"
  alarm_description   = "Scale in by 1 when ASG average CPU stays below 10%"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Average"
  threshold           = 10
  alarm_actions       = [aws_autoscaling_policy.scale_in.arn]

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.app.name
  }
}

# Nginx EC2 in public subnet
resource "aws_instance" "nginx" {
  ami                         = var.nginx_ami_id
  instance_type               = "t3.micro"
  subnet_id                   = var.public_subnet_ids[0]
  vpc_security_group_ids      = [aws_security_group.nginx_sg.id]
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.ec2_profile.name

  user_data = base64encode(trimspace(<<-EOF
    #!/bin/bash
    dnf update -y
    dnf install -y nginx python3 python3-pip
    pip3 install ansible boto3 botocore
    systemctl enable nginx
EOF
  ))

  tags = {
    Name = "${var.project_name}-nginx"
    Role = "nginx"
  }
}

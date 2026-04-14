"""
Generate a polished architecture diagram for the capstone using:
https://github.com/mingrammer/diagrams

Prerequisites:
    pip install diagrams
    # Graphviz is already installed on this machine

Run from the repo root or docs directory:
    python3 docs/architecture_diagram.py

Output:
    docs/architecture-diagrams.png
"""

from pathlib import Path

from diagrams import Cluster, Diagram, Edge
from diagrams.aws.compute import EC2, EC2AutoScaling
from diagrams.aws.database import RDS
from diagrams.aws.management import AutoScaling, CloudwatchAlarm, SystemsManager
from diagrams.aws.network import (
    ElbApplicationLoadBalancer,
    InternetGateway,
    NATGateway,
)
from diagrams.aws.storage import S3
from diagrams.aws.database import Dynamodb
from diagrams.onprem.client import User
from diagrams.onprem.container import Docker
from diagrams.onprem.iac import Ansible
from diagrams.onprem.vcs import Github


DOCS_DIR = Path(__file__).resolve().parent
OUTFILE = str(DOCS_DIR / "architecture-diagrams")


graph_attr = {
    "pad": "0.8",
    "nodesep": "1.0",
    "ranksep": "1.0",
    "splines": "spline",
    "fontname": "Helvetica",
    "fontsize": "24",
    "labelloc": "t",
    "labeljust": "l",
    "bgcolor": "white",
}

node_attr = {
    "fontname": "Helvetica",
    "fontsize": "16",
}


with Diagram(
    "AWS Auto-Scale Stack Architecture",
    filename=OUTFILE,
    outformat=["png", "svg"],
    show=False,
    direction="LR",
    graph_attr=graph_attr,
    node_attr=node_attr,
):
    users = User("End Users")
    docker = Docker("Docker-based\nAnsible control node")
    ansible = Ansible("Ansible\nvia SSM")
    github = Github("GitHub repo")

    with Cluster("AWS us-east-1\nVPC 10.0.0.0/16"):
        igw = InternetGateway("Internet\nGateway")

        with Cluster("Public Subnets\n10.0.1.0/24 • 10.0.2.0/24"):
            nginx = EC2("Nginx EC2\npublic frontend")
            alb = ElbApplicationLoadBalancer("ALB\n/api -> Flask")
            nat = NATGateway("NAT Gateway")

        with Cluster("Private Subnets\n10.0.3.0/24 • 10.0.4.0/24"):
            asg = EC2AutoScaling("ASG\nFlask app tier\nmin 2 / max 6")
            app_nodes = [EC2("App instance A"), EC2("App instance B")]
            rds = RDS("RDS MySQL 8.0\nappdb")

        with Cluster("Operations & State"):
            ssm = SystemsManager("Systems Manager")
            cw = AutoScaling("CloudWatch metrics\nCPU + instance count")
            cpu_high = CloudwatchAlarm("cpu-high\n>20% for 2x60s")
            cpu_low = CloudwatchAlarm("cpu-low\n<10% for 3x60s")
            state_bucket = S3("S3 remote state")
            state_lock = Dynamodb("DynamoDB lock")

    users >> Edge(label="HTTP") >> igw
    igw >> Edge(label=":80 / :443") >> nginx
    igw >> Edge(label=":80") >> alb
    nginx >> Edge(label="/api/* proxy") >> alb

    alb >> Edge(label=":5000") >> asg
    asg >> app_nodes
    app_nodes >> Edge(label="MySQL 3306") >> rds

    cpu_high >> Edge(color="firebrick", style="dashed", label="+1") >> asg
    cpu_low >> Edge(color="steelblue", style="dashed", label="-1") >> asg
    cw >> Edge(style="dashed", label="observes") >> asg
    cw >> Edge(style="dashed", label="drives alarms") >> cpu_high
    cw >> Edge(style="dashed", label="drives alarms") >> cpu_low

    docker >> ansible >> Edge(label="SSM") >> ssm
    ssm >> Edge(label="initial config") >> nginx
    ssm >> Edge(label="manual app config") >> asg

    github >> Edge(label="git clone at launch") >> asg
    nat >> Edge(style="dashed", label="outbound only") >> github
    docker >> Edge(style="dashed", label="Terraform") >> state_bucket
    docker >> Edge(style="dashed", label="state lock") >> state_lock
    users - Edge(style="invis") - docker
    state_bucket - Edge(style="invis") - state_lock
    cpu_high - Edge(style="invis") - cpu_low

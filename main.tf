provider "aws" {
  region = "ap-southeast-1"
}

# -----------------------------
# VPC + Subnets + Routing
# -----------------------------
resource "aws_vpc" "demo_vpc" {
  cidr_block = "10.10.0.0/16"
}

resource "aws_subnet" "subnet_az1" {
  vpc_id                  = aws_vpc.demo_vpc.id
  cidr_block              = "10.10.1.0/24"
  availability_zone       = "ap-southeast-1a"
  map_public_ip_on_launch = true
}

resource "aws_subnet" "subnet_az2" {
  vpc_id                  = aws_vpc.demo_vpc.id
  cidr_block              = "10.10.2.0/24"
  availability_zone       = "ap-southeast-1b"
  map_public_ip_on_launch = true
}

resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.demo_vpc.id
}

resource "aws_route_table" "route_table" {
  vpc_id = aws_vpc.demo_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }
}

resource "aws_route_table_association" "subnet_az1_assoc" {
  subnet_id      = aws_subnet.subnet_az1.id
  route_table_id = aws_route_table.route_table.id
}

resource "aws_route_table_association" "subnet_az2_assoc" {
  subnet_id      = aws_subnet.subnet_az2.id
  route_table_id = aws_route_table.route_table.id
}

# -----------------------------
# Security Group
# -----------------------------
resource "aws_security_group" "ec2_sg" {
  name        = "multi-az-sg"
  description = "Allow inbound traffic for demo stack"
  vpc_id      = aws_vpc.demo_vpc.id

  # Allow inbound HTTP for ALB
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow common ports (Kafka/Redis/Mongo/Postgre)
  ingress {
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# -----------------------------
# User-data: install Docker + Docker Compose
# -----------------------------
locals {
  user_data = <<-EOF
    #!/bin/bash
    yum update -y
    amazon-linux-extras install docker -y
    yum install -y git
    systemctl start docker
    systemctl enable docker
    usermod -a -G docker ec2-user

    curl -L \
      "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64" \
      -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose

    # Auto clone docker-compose file (OPTIONAL)
    # git clone https://github.com/your/repo.git /home/ec2-user/app
    # cd /home/ec2-user/app
    # docker-compose up -d

  EOF
}

# -----------------------------
# EC2 Instances (Multi-AZ)
# -----------------------------
resource "aws_instance" "ec2_az1" {
  ami           = "ami-00002920817981683"   # UPDATE THIS
  instance_type = "t3.large"
  subnet_id     = aws_subnet.subnet_az1.id
  security_groups = [aws_security_group.ec2_sg.id]
  user_data     = local.user_data
  tags = {
    Name = "multi-az-ec2-a"
  }
  key_name = "EC2-1"
  root_block_device {
    volume_size = 16
    volume_type = "gp2"
  }
}

resource "aws_instance" "ec2_az2" {
  ami           = "ami-00002920817981683"   # UPDATE THIS
  instance_type = "t3.large"
  subnet_id     = aws_subnet.subnet_az2.id
  security_groups = [aws_security_group.ec2_sg.id]
  user_data     = local.user_data
  tags = {
    Name = "multi-az-ec2-b"
  }
  key_name = "EC2-2"
  root_block_device {
    volume_size = 16
    volume_type = "gp2"
  }
}

# -----------------------------
# Load Balancer (ALB)
# -----------------------------
resource "aws_lb" "alb" {
  name               = "multi-az-alb"
  load_balancer_type = "application"
  security_groups    = [aws_security_group.ec2_sg.id]
  subnets            = [
    aws_subnet.subnet_az1.id,
    aws_subnet.subnet_az2.id
  ]
}

resource "aws_lb_target_group" "tg" {
  name     = "multi-az-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.demo_vpc.id

  health_check {
    path                = "/"
    port                = "80"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 10
    timeout             = 5
  }
}

resource "aws_lb_listener" "listener" {
  load_balancer_arn = aws_lb.alb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg.arn
  }
}

resource "aws_lb_target_group_attachment" "az1_attach" {
  target_group_arn = aws_lb_target_group.tg.arn
  target_id        = aws_instance.ec2_az1.id
  port             = 80
}

resource "aws_lb_target_group_attachment" "az2_attach" {
  target_group_arn = aws_lb_target_group.tg.arn
  target_id        = aws_instance.ec2_az2.id
  port             = 80
}

# -----------------------------
# Output
# -----------------------------
output "ALB_URL" {
  value = aws_lb.alb.dns_name
}

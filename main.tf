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
  iam_instance_profile   = aws_iam_instance_profile.ec2_profile.name
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
  iam_instance_profile   = aws_iam_instance_profile.ec2_profile.name
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

# Auth Service Target Group
resource "aws_lb_target_group" "auth_tg" {
  name     = "auth-service-tg"
  port     = 3030
  protocol = "HTTP"
  vpc_id   = aws_vpc.demo_vpc.id

  health_check {
    path                = "/actuator/health"
    port                = "3030"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 30
    timeout             = 5
    matcher             = "200"
  }

  tags = {
    Name = "auth-service-target-group"
  }
}

# Driver Service Target Group
resource "aws_lb_target_group" "driver_tg" {
  name     = "driver-service-tg"
  port     = 3031
  protocol = "HTTP"
  vpc_id   = aws_vpc.demo_vpc.id

  health_check {
    path                = "/actuator/health"
    port                = "3031"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 30
    timeout             = 5
    matcher             = "200"
  }

  tags = {
    Name = "driver-service-target-group"
  }
}

# Trip Service Target Group
resource "aws_lb_target_group" "trip_tg" {
  name     = "trip-service-tg"
  port     = 3032
  protocol = "HTTP"
  vpc_id   = aws_vpc.demo_vpc.id

  health_check {
    path                = "/actuator/health"
    port                = "3032"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 30
    timeout             = 5
    matcher             = "200"
  }

  tags = {
    Name = "trip-service-target-group"
  }
}

resource "aws_lb_listener" "listener" {
  load_balancer_arn = aws_lb.alb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Welcome to Multi-AZ Microservices API\nAvailable endpoints:\n/api/auth/*\n/api/drivers/*\n/api/trips/*"
      status_code  = "200"
    }
  }
}

# Auth Service Listener Rule
resource "aws_lb_listener_rule" "auth_rule" {
  listener_arn = aws_lb_listener.listener.arn
  priority     = 100

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.auth_tg.arn
  }

  condition {
    path_pattern {
      values = ["/api/auth/*"]
    }
  }

  tags = {
    Name = "auth-service-rule"
  }
}

# Driver Service Listener Rule
resource "aws_lb_listener_rule" "driver_rule" {
  listener_arn = aws_lb_listener.listener.arn
  priority     = 200

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.driver_tg.arn
  }

  condition {
    path_pattern {
      values = ["/api/drivers/*"]
    }
  }

  tags = {
    Name = "driver-service-rule"
  }
}

# Trip Service Listener Rule
resource "aws_lb_listener_rule" "trip_rule" {
  listener_arn = aws_lb_listener.listener.arn
  priority     = 300

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.trip_tg.arn
  }

  condition {
    path_pattern {
      values = ["/api/trips/*"]
    }
  }

  tags = {
    Name = "trip-service-rule"
  }
}

# Health Check Rule (routes to auth service for general health)
resource "aws_lb_listener_rule" "health_rule" {
  listener_arn = aws_lb_listener.listener.arn
  priority     = 400

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.auth_tg.arn
  }

  condition {
    path_pattern {
      values = ["/actuator/health", "/health"]
    }
  }

  tags = {
    Name = "health-check-rule"
  }
}

# CloudWatch Logs IAM Role
resource "aws_iam_role" "ec2_cloudwatch_role" {
  name = "ec2-cloudwatch-logs-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name = "EC2 CloudWatch Logs Role"
  }
}

# CloudWatch Logs IAM Policy
resource "aws_iam_role_policy" "ec2_cloudwatch_policy" {
  name = "ec2-cloudwatch-logs-policy"
  role = aws_iam_role.ec2_cloudwatch_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream", 
          "logs:PutLogEvents",
          "logs:DescribeLogStreams"
        ]
        Resource = "*"
      }
    ]
  })
}

# Instance Profile
resource "aws_iam_instance_profile" "ec2_profile" {
  name = "ec2-cloudwatch-profile"
  role = aws_iam_role.ec2_cloudwatch_role.name
}

# Auth Service Target Group Attachments
resource "aws_lb_target_group_attachment" "auth_az1" {
  target_group_arn = aws_lb_target_group.auth_tg.arn
  target_id        = aws_instance.ec2_az1.id
  port             = 3030
}

resource "aws_lb_target_group_attachment" "auth_az2" {
  target_group_arn = aws_lb_target_group.auth_tg.arn
  target_id        = aws_instance.ec2_az2.id
  port             = 3030
}

# Driver Service Target Group Attachments
resource "aws_lb_target_group_attachment" "driver_az1" {
  target_group_arn = aws_lb_target_group.driver_tg.arn
  target_id        = aws_instance.ec2_az1.id
  port             = 3031
}

resource "aws_lb_target_group_attachment" "driver_az2" {
  target_group_arn = aws_lb_target_group.driver_tg.arn
  target_id        = aws_instance.ec2_az2.id
  port             = 3031
}

# Trip Service Target Group Attachments
resource "aws_lb_target_group_attachment" "trip_az1" {
  target_group_arn = aws_lb_target_group.trip_tg.arn
  target_id        = aws_instance.ec2_az1.id
  port             = 3032
}

resource "aws_lb_target_group_attachment" "trip_az2" {
  target_group_arn = aws_lb_target_group.trip_tg.arn
  target_id        = aws_instance.ec2_az2.id
  port             = 3032
}

# -----------------------------
# Outputs
# -----------------------------
output "ALB_URL" {
  description = "Application Load Balancer DNS name"
  value       = aws_lb.alb.dns_name
}

output "ALB_ZONE_ID" {
  description = "Application Load Balancer Zone ID"
  value       = aws_lb.alb.zone_id
}

output "EC2_AZ1_IP" {
  description = "EC2 AZ1 Public IP"
  value       = aws_instance.ec2_az1.public_ip
}

output "EC2_AZ2_IP" {
  description = "EC2 AZ2 Public IP"
  value       = aws_instance.ec2_az2.public_ip
}

output "API_ENDPOINTS" {
  description = "Available API endpoints through ALB"
  value = {
    "Auth Service"   = "http://${aws_lb.alb.dns_name}/api/auth/"
    "Driver Service" = "http://${aws_lb.alb.dns_name}/api/drivers/"
    "Trip Service"   = "http://${aws_lb.alb.dns_name}/api/trips/"
    "Health Check"   = "http://${aws_lb.alb.dns_name}/actuator/health"
  }
}

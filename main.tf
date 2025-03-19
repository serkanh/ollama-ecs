terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  required_version = ">= 1.2.0"
}

provider "aws" {
  region = var.aws_region
}

# Data sources for existing VPC and subnets
data "aws_vpc" "existing_vpc" {
  id = var.vpc_id
}

data "aws_subnets" "public" {
  filter {
    name   = "tag:subnet"
    values = ["public"]
  }
}

# Add data source for private subnets
data "aws_subnets" "private" {
  filter {
    name   = "tag:subnet"
    values = ["private"]
  }
}

# Add data source for private subnets in supported AZs
data "aws_availability_zones" "available" {
  state = "available"
  filter {
    name   = "zone-name"
    values = ["us-east-1a", "us-east-1c", "us-east-1d", "us-east-1e", "us-east-1f"]  # AZs that support g4dn.xlarge
  }
}

# Get private subnets in supported AZs
data "aws_subnet" "private_subnets" {
  for_each = toset(data.aws_subnets.private.ids)
  id       = each.value
}

locals {
  # Filter private subnets to only those in supported AZs
  supported_private_subnet_ids = [
    for subnet_id, subnet in data.aws_subnet.private_subnets : subnet_id
    if contains(data.aws_availability_zones.available.names, subnet.availability_zone)
  ]
}

# Create ECS cluster with Service Connect enabled
resource "aws_ecs_cluster" "ollama_cluster" {
  name = "ollama-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  service_connect_defaults {
    namespace = aws_service_discovery_http_namespace.service_namespace.arn
  }
}

# Create IAM role for EC2 instance profile
resource "aws_iam_role" "ecs_instance_role" {
  name = "ecs-instance-role"

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
}

# Attach policies to EC2 instance role
resource "aws_iam_role_policy_attachment" "ecs_instance_role_attachment" {
  role       = aws_iam_role.ecs_instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

# Attach SSM policy to EC2 instance role
resource "aws_iam_role_policy_attachment" "ecs_instance_ssm_policy" {
  role       = aws_iam_role.ecs_instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Create instance profile
resource "aws_iam_instance_profile" "ecs_instance_profile" {
  name = "ecs-instance-profile"
  role = aws_iam_role.ecs_instance_role.name
}

# Create security group for EC2 instances
resource "aws_security_group" "ecs_instance_sg" {
  name        = "ecs-instance-sg"
  description = "Security group for ECS EC2 instances"
  vpc_id      = data.aws_vpc.existing_vpc.id

  ingress {
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    security_groups = [aws_security_group.lb_sg.id]
  }

  # Allow SSH access for SSM
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow SSH for SSM Session Manager"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Add tags for easier identification
  tags = {
    Name = "ecs-instance-sg"
  }
}

# Create EC2 launch template for ECS
resource "aws_launch_template" "ecs_launch_template" {
  name_prefix   = "ecs-gpu-"
  image_id      = var.ami_id
  instance_type = "g4dn.xlarge"            # Changed to g4dn.xlarge which is more widely available
  key_name      = var.ssh_key_name         # Add SSH key for direct SSH access

  iam_instance_profile {
    name = aws_iam_instance_profile.ecs_instance_profile.name
  }

  vpc_security_group_ids = [aws_security_group.ecs_instance_sg.id]

  user_data = base64encode(<<-EOF
    #!/bin/bash
    echo ECS_CLUSTER=${aws_ecs_cluster.ollama_cluster.name} >> /etc/ecs/ecs.config
    echo ECS_ENABLE_GPU_SUPPORT=true >> /etc/ecs/ecs.config
    # Install NVIDIA drivers and Docker GPU runtime
    yum update -y
    yum install -y gcc kernel-devel-$(uname -r)
    amazon-linux-extras install -y docker
    systemctl start docker
    systemctl enable docker

    # Ensure SSM agent is running
    systemctl enable amazon-ssm-agent
    systemctl start amazon-ssm-agent
  EOF
  )

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size = 100
      volume_type = "gp3"
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "ecs-gpu-instance"
    }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "optional"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }
}

# Create Auto Scaling Group for ECS
resource "aws_autoscaling_group" "ecs_asg" {
  name                = "ecs-gpu-asg"
  vpc_zone_identifier = local.supported_private_subnet_ids  # Use only private subnets in supported AZs
  min_size            = 0
  max_size            = 1
  desired_capacity    = 0

  # Add health check configuration
  health_check_type         = "EC2"
  health_check_grace_period = 300

  launch_template {
    id      = aws_launch_template.ecs_launch_template.id
    version = "$Latest"
  }

  tag {
    key                 = "AmazonECSManaged"
    value               = true
    propagate_at_launch = true
  }

  # Add lifecycle hook to wait for instance to be ready
  lifecycle {
    create_before_destroy = true
  }
}

# Create EC2 capacity provider
resource "aws_ecs_capacity_provider" "ec2_capacity_provider" {
  name = "ec2-gpu-capacity-provider"

  auto_scaling_group_provider {
    auto_scaling_group_arn = aws_autoscaling_group.ecs_asg.arn

    managed_scaling {
      maximum_scaling_step_size = 1
      minimum_scaling_step_size = 1
      status                    = "ENABLED"
      target_capacity           = 100
    }
  }
}

# Attach capacity provider to cluster
resource "aws_ecs_cluster_capacity_providers" "cluster_capacity_providers" {
  cluster_name = aws_ecs_cluster.ollama_cluster.name
  capacity_providers = [aws_ecs_capacity_provider.ec2_capacity_provider.name]

  default_capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.ec2_capacity_provider.name
    weight            = 100
  }
}

# Create Service Connect namespace
resource "aws_service_discovery_http_namespace" "service_namespace" {
  name = "ollama-webui-namespace"
}

# Create security groups
resource "aws_security_group" "ollama_sg" {
  name        = "ollama-service-sg"
  description = "Security group for Ollama service"
  vpc_id      = data.aws_vpc.existing_vpc.id

  ingress {
    from_port   = 11434
    to_port     = 11434
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

resource "aws_security_group" "webui_sg" {
  name        = "webui-service-sg"
  description = "Security group for WebUI service"
  vpc_id      = data.aws_vpc.existing_vpc.id

  ingress {
    from_port   = 8080
    to_port     = 8080
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

# Allow WebUI to communicate with Ollama
resource "aws_security_group_rule" "webui_to_ollama" {
  type                     = "ingress"
  from_port                = 11434
  to_port                  = 11434
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.webui_sg.id
  security_group_id        = aws_security_group.ollama_sg.id
  description              = "Allow WebUI service to communicate with Ollama service"
}

# Create IAM roles for task execution
resource "aws_iam_role" "ecs_task_execution_role" {
  name = "ecs-task-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_role_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Create CloudWatch log groups with 1-day retention
resource "aws_cloudwatch_log_group" "ollama_log_group" {
  name              = "/ecs/ollama-service"
  retention_in_days = 1
}

resource "aws_cloudwatch_log_group" "webui_log_group" {
  name              = "/ecs/webui-service"
  retention_in_days = 1
}

# Single ALB for both services
resource "aws_lb" "shared_lb" {
  name               = "ollama-webui-lb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.lb_sg.id]
  subnets            = data.aws_subnets.public.ids
}

# Security group for the shared ALB
resource "aws_security_group" "lb_sg" {
  name        = "shared-lb-sg"
  description = "Security group for shared load balancer"
  vpc_id      = data.aws_vpc.existing_vpc.id

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
}

# Ollama Target Group
resource "aws_lb_target_group" "ollama_tg" {
  name        = "ollama-tg"
  port        = 11434
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.existing_vpc.id
  target_type = "ip"

  health_check {
    path                = "/"
    port                = 11434
    timeout             = 120
    interval            = 240
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

# WebUI Target Group
resource "aws_lb_target_group" "webui_tg" {
  name        = "webui-tg"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.existing_vpc.id
  target_type = "ip"

  health_check {
    path                = "/"
    port                = "8080"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 30
    interval            = 60
    matcher             = "200-399"
  }
}

# Main listener on port 80
resource "aws_lb_listener" "http_listener" {
  load_balancer_arn = aws_lb.shared_lb.arn
  port              = 80
  protocol          = "HTTP"

  # Default action points to WebUI
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.webui_tg.arn
  }
}

# Keep only the host-based routing for Ollama API
resource "aws_lb_listener_rule" "host_header_api_rule" {
  listener_arn = aws_lb_listener.http_listener.arn
  priority     = 20

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ollama_tg.arn
  }

  # Match based on host header
  condition {
    host_header {
      values = ["api.*", "ollama.*"]
    }
  }
}

# Ollama Task Definition with GPU support
resource "aws_ecs_task_definition" "ollama_task" {
  family                   = "ollama-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["EC2"]
  cpu                      = 2048
  memory                   = 5120
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn

  container_definitions = jsonencode([
    {
      name      = "ollama-container"
      image     = "ollama/ollama:latest"
      essential = true

      portMappings = [
        {
          name           = "ollama-port"
          containerPort = 11434
          hostPort      = 11434
          protocol      = "tcp"
          appProtocol   = "http"
        }
      ]

      environment = [
        {
          name  = "OLLAMA_HOST"
          value = "0.0.0.0"
        }
      ]

      # Add GPU resource requirement
      resourceRequirements = [
        {
          type  = "GPU"
          value = "1"
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = "/ecs/ollama-service"
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "ollama"
          "awslogs-create-group"  = "true"
        }
      }
    }
  ])
}

# WebUI Task Definition
resource "aws_ecs_task_definition" "webui_task" {
  family                   = "webui-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["EC2"]
  cpu                      = 2048
  memory                   = 5120
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn

  container_definitions = jsonencode([
    {
      name      = "webui-container"
      image     = "ghcr.io/open-webui/open-webui:main"
      essential = true

      portMappings = [
        {
          name           = "webui-port"
          containerPort = 8080
          hostPort      = 8080
          protocol      = "tcp"
          appProtocol   = "http"
        }
      ]

      environment = [
        {
          name  = "OLLAMA_BASE_URL"
          value = "http://ollama.internal:11434"
        },
        {
          name  = "WEBUI_SECRET_KEY"
          value = var.webui_secret_key
        },
        {
          name  = "MODEL_FILTER_ENABLED"
          value = "false"
        },
        {
          name  = "WEBUI_DEBUG_MODE"
          value = "true"
        },
        {
          name  = "OLLAMA_API_OVERRIDE_BASE_URL"
          value = "http://ollama.internal:11434"
        },
        {
          name  = "OLLAMA_API_BASE_URL"
          value = "http://ollama.internal:11434"
        },
        {
          name  = "ENABLE_OLLAMA_MANAGEMENT"
          value = "true"
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = "/ecs/webui-service"
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "webui"
          "awslogs-create-group"  = "true"
        }
      }
    }
  ])

  depends_on = [aws_lb.shared_lb]
}

# Ollama Service with EC2 launch type
resource "aws_ecs_service" "ollama_service" {
  name            = "ollama-service"
  cluster         = aws_ecs_cluster.ollama_cluster.id
  task_definition = aws_ecs_task_definition.ollama_task.arn
  desired_count   = 1
  launch_type     = null  # Not using launch_type with capacity providers

  capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.ec2_capacity_provider.name
    weight            = 100
  }

  network_configuration {
    subnets          = local.supported_private_subnet_ids  # Use only private subnets in supported AZs
    security_groups  = [aws_security_group.ollama_sg.id]
    assign_public_ip = false  # No public IP needed in private subnets
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.ollama_tg.arn
    container_name   = "ollama-container"
    container_port   = 11434
  }

  # Service Connect Configuration
  service_connect_configuration {
    enabled   = true
    namespace = aws_service_discovery_http_namespace.service_namespace.arn

    service {
      port_name      = "ollama-port"
      discovery_name = "ollama"
      client_alias {
        port     = 11434
        dns_name = "ollama.internal"
      }
    }
  }

  depends_on = [aws_lb_listener_rule.host_header_api_rule, aws_ecs_cluster_capacity_providers.cluster_capacity_providers]
}

# WebUI Service with EC2 launch type
resource "aws_ecs_service" "webui_service" {
  name            = "webui-service"
  cluster         = aws_ecs_cluster.ollama_cluster.id
  task_definition = aws_ecs_task_definition.webui_task.arn
  desired_count   = 1
  launch_type     = null  # Not using launch_type with capacity providers

  capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.ec2_capacity_provider.name
    weight            = 100
  }

  network_configuration {
    subnets          = local.supported_private_subnet_ids  # Use only private subnets in supported AZs
    security_groups  = [aws_security_group.webui_sg.id]
    assign_public_ip = false  # No public IP needed in private subnets
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.webui_tg.arn
    container_name   = "webui-container"
    container_port   = 8080
  }

  # Service Connect Configuration
  service_connect_configuration {
    enabled   = true
    namespace = aws_service_discovery_http_namespace.service_namespace.arn

    service {
      port_name      = "webui-port"
      discovery_name = "webui"
      client_alias {
        port     = 8080
        dns_name = "webui.internal"
      }
    }
  }

  depends_on = [aws_ecs_service.ollama_service, aws_lb_listener.http_listener, aws_ecs_cluster_capacity_providers.cluster_capacity_providers]
}

# Outputs
output "shared_lb_dns" {
  description = "DNS name for the shared load balancer"
  value       = aws_lb.shared_lb.dns_name
}

output "webui_url" {
  description = "URL for accessing the WebUI interface"
  value       = "http://${aws_lb.shared_lb.dns_name}"
}

output "model_pull_command" {
  description = "Command to pull the DeepSeek-R1 model"
  value       = "curl -X POST http://${aws_lb.shared_lb.dns_name}/api/pull -d '{\"name\": \"deepseek-r1:7b\"}'"
}
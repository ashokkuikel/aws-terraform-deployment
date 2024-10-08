provider "aws" {
  region = "us-west-2"
}

variable "db_username" {
  description = "The database username"
}

variable "db_password" {
  description = "The database password"
  sensitive   = true
}


locals {
  app_name = "wordpress-ecs"
}

# Add the IAM roles and CloudWatch log group here

resource "aws_iam_role" "ecs_execution_role" {
  name = "ecs-execution-role"

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

  lifecycle {
    create_before_destroy = true
    ignore_changes        = [name]
    prevent_destroy       = true
  }
}


resource "aws_iam_role" "ecs_task_role" {
  name = "ecs-task-role"

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

resource "aws_cloudwatch_log_group" "main" {
  name = local.app_name
}

resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"

  tags = {
    Name = local.app_name
  }
}

resource "aws_subnet" "private" {
  count = 2

  cidr_block = "10.0.${count.index + 1}.0/24"
  vpc_id     = aws_vpc.main.id
  availability_zone = "us-west-2${count.index < 2 ? "a" : "b"}" # Change this line

  tags = {
    Name = "${local.app_name}-private-${count.index + 1}"
  }
}


resource "aws_security_group" "ecs_service" {
  name        = "ecs-service"
  description = "Allow inbound traffic to ECS service"
  vpc_id      = aws_vpc.main.id
}

resource "aws_security_group" "rds" {
  name        = "rds"
  description = "Allow connections to RDS from ECS instances"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs_service.id]
  }
}


resource "aws_db_instance" "wordpress" {
  identifier             = "wordpress-db"
  allocated_storage      = 20
  engine                 = "mysql"
  engine_version         = "8.0"
  instance_class         = "db.t2.micro"
  name                   = "wordpress-db"
  username               = var.db_username
  password               = var.db_password
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  skip_final_snapshot    = true

  tags = {
    Name = local.app_name
  }
}

resource "aws_lb" "main" {
  name               = "wordpress-alb"
  load_balancer_type = "application"

  subnets = [
    aws_subnet.private[0].id,
    aws_subnet.private[1].id,
  ]

  security_groups = [
    aws_security_group.alb.id,
  ]
  
  tags = {
    Name = local.app_name
  }
}


resource "aws_lb_target_group" "main" {
  name     = "wordpress-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    enabled             = true
    interval            = 30
    path                = "/"
    port                = "traffic-port"
    healthy_threshold   = 3
    unhealthy_threshold = 3
    timeout             = 5
  }
}

resource "aws_lb_listener" "main" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.main.arn
  }
}

resource "aws_db_subnet_group" "main" {
  name       = "main"
  subnet_ids = aws_subnet.private.*.id
}

resource "aws_ecr_repository" "wordpress" {
  name = local.app_name
}

resource "aws_ecs_cluster" "main" {
  name = local.app_name
}

resource "aws_ecs_service" "main" {
  name            = local.app_name
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.main.arn
  launch_type     = "FARGATE"

  desired_count = 1

  network_configuration {
    subnets          = aws_subnet.private.*.id
    security_groups  = [aws_security_group.ecs_service.id]
    assign_public_ip = false
  }

  depends_on = [aws_lb_listener.main]
}

resource "aws_ecs_task_definition" "main" {
  family                   = local.app_name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  execution_role_arn       = aws_iam_role.ecs_execution_role.arn
  task_role_arn            = aws_iam_role.ecs_task_role.arn
  cpu                      = "256"
  memory                   = "512"

  container_definitions = jsonencode([
    {
      name  = local.app_name
      image = "${aws_ecr_repository.wordpress.repository_url}:latest"
      
      portMappings = [
        {
          containerPort = 80
          hostPort      = 80
          protocol      = "tcp"
        }
      ]

      environment = [
        {
          name  = "WORDPRESS_DB_NAME"
          value = "your_db_name"
        },
        {
          name  = "WORDPRESS_DB_USER"
          value = var.db_username
        },
        {
          name  = "WORDPRESS_DB_PASSWORD"
          value = var.db_password
        },
        {
          name  = "WORDPRESS_DB_HOST"
          value = aws_db_instance.wordpress.endpoint
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"

        options = {
          "awslogs-region"        = "us-west-2"
          "awslogs-group"         = aws_cloudwatch_log_group.main.name
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])
}

# Add the worker task definition here
resource "aws_ecs_task_definition" "worker" {
  family                   = "${local.app_name}-worker"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  execution_role_arn       = aws_iam_role.ecs_execution_role.arn
  task_role_arn            = aws_iam_role.ecs_task_role.arn
  cpu                      = "256"
  memory                   = "512"
  
  container_definitions = jsonencode([
    {
      name  = "worker"
      image = "${aws_ecr_repository.wordpress.repository_url}:<TAG>"
      
      environment = [
        {
          name  = "WORDPRESS_DB_NAME"
          value = "your_db_name"
        },
        {
          name  = "WORDPRESS_DB_USER"
          value = var.db_username
        },
        {
          name  = "WORDPRESS_DB_PASSWORD"
          value = var.db_password
        },
        {
          name  = "WORDPRESS_DB_HOST"
          value = aws_db_instance.wordpress.endpoint
        }
      ]
      
      logConfiguration = {
        logDriver = "awslogs"

        options = {
          "awslogs-region"        = "us-west-2"
          "awslogs-group"         = aws_cloudwatch_log_group.main.name
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])
}

# Create an ECS service for the worker task definition
resource "aws_ecs_service" "worker" {
  name            = "${local.app_name}-worker"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.worker.arn
  launch_type     = "FARGATE"

  desired_count = 1

  network_configuration {
    subnets          = aws_subnet.private.*.id
    security_groups  = [aws_security_group.ecs_service.id]
    assign_public_ip = false
  }
} 

# Create a CloudWatch event rule to trigger the worker task on a schedule
resource "aws_cloudwatch_event_rule" "worker" {
  name        = "${local.app_name}-worker"
  schedule_expression = "rate(1 hour)"
}

# Add a target to the CloudWatch event rule to run the worker task
resource "aws_cloudwatch_event_target" "worker" {
  rule      = aws_cloudwatch_event_rule.worker.name
  arn       = aws_ecs_cluster.main.arn
  role_arn  = aws_iam_role.ecs_execution_role.arn
  
  ecs_target {
    task_count          = 1
    task_definition_arn = aws_ecs_task_definition.worker.arn
    
    network_configuration {
      subnets          = aws_subnet.private.*.id
      security_groups  = [aws_security_group.ecs_service.id]
      assign_public_ip = false
    }
  }
}

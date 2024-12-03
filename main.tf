# Defining VPC
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
  enable_dns_support = true
  enable_dns_hostnames = true
}

# Declare the data source to fetch available availability zones
data "aws_availability_zones" "available" {}

# Define the Internet Gateway and attach it to the VPC
resource "aws_internet_gateway" "main_igw" {
  vpc_id = aws_vpc.main.id
}

# Define Subnets 
resource "aws_subnet" "subnet_ids" {
  count = 2

  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(aws_vpc.main.cidr_block, 8, count.index)
  availability_zone       = element(data.aws_availability_zones.available.names, count.index)
  map_public_ip_on_launch = true
  tags = {
    Name = "Subnetwork-${count.index}"
  }
}

# Define the Security Group for the Load Balancer
resource "aws_security_group" "lb_sg" {
  name        = "spartanmarket-lb-sg"
  description = "Allow inbound HTTP traffic for the load balancer"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
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

# Define Load Balancer with dependency on the security group
resource "aws_lb" "spartanmarket_lb" {
  name               = "spartanmarket-lb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.lb_sg.id]
  subnets            = aws_subnet.subnet_ids[*].id
  depends_on         = [aws_security_group.lb_sg]
}

# Define Route 53 DNS Zone
resource "aws_route53_zone" "spartanmarket" {
  name = "spartanmarket.sjsu.edu"
}

# Define Cognito User Pool
resource "aws_cognito_user_pool" "sjsu_students" {
  name = "SJSU_Student_User_Pool"
}

# Define Cognito User Pool Client
resource "aws_cognito_user_pool_client" "sjsu_client" {
  user_pool_id = aws_cognito_user_pool.sjsu_students.id
  name         = "SpartanMarketClient"
}

# Define Launch Template for EC2 Instances (replacing Launch Configuration)
resource "aws_launch_template" "spartanmarket_launch_template" {
  name_prefix   = "spartanmarket-launch-template"
  image_id      = "ami-0819a8650d771b8be"  
  instance_type = "t2.micro"

  user_data = base64encode(<<-EOF
              #!/bin/bash
              cd /home/ubuntu
              git clone https://github.com/your-repository/spartanmarket.git
              cd spartanmarket
              sudo docker-compose up -d
              EOF
  )

  lifecycle {
    create_before_destroy = true
  }

  network_interfaces {
    associate_public_ip_address = true
    security_groups            = [aws_security_group.lb_sg.id]
  }
}

# Update Auto Scaling Group to use the Launch Template
resource "aws_autoscaling_group" "spartanmarket_asg" {
  desired_capacity     = 2
  max_size             = 3
  min_size             = 1
  vpc_zone_identifier  = aws_subnet.subnet_ids[*].id

  launch_template {
    id      = aws_launch_template.spartanmarket_launch_template.id
    version = "$Latest"  
  }

  health_check_type         = "EC2"
  health_check_grace_period = 300
  wait_for_capacity_timeout  = "0"

  tag {
    key                 = "Name"
    value               = "SpartanMarketInstance"
    propagate_at_launch = true
  }
}

# Define RDS Instance with engine specified and compatible instance class
resource "aws_db_instance" "spartanmarket_db" {
  identifier        = "spartanmarket-db"
  engine            = "mysql"
  engine_version    = "8.0.32"
  username          = "admin"
  password          = "purvi123"
  instance_class    = "db.t3.micro"
  allocated_storage = 20
  storage_type      = "gp2"
  multi_az          = true 
  publicly_accessible = true
  db_subnet_group_name  = aws_db_subnet_group.spartanmarket_db_subnet_group.name
  backup_retention_period = 7
}

# Define DB Subnet Group for RDS
resource "aws_db_subnet_group" "spartanmarket_db_subnet_group" {
  name       = "spartanmarket-db-subnet-group"
  subnet_ids = aws_subnet.subnet_ids[*].id
}

# Define CloudWatch CPU Utilization Alarm for Auto Scaling Group
resource "aws_cloudwatch_metric_alarm" "cpu_alarm" {
  alarm_name          = "high-cpu-utilization"
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 5

  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  statistic           = "Average"
  period              = 300
  alarm_description   = "This alarm triggers when CPU utilization exceeds 80%."
  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.spartanmarket_asg.name
  }

  alarm_actions = [
    aws_sns_topic.spartanmarket_alerts.arn
  ]
}

# Define S3 Bucket for media and backups with versioning enabled
resource "aws_s3_bucket" "spartanmarket" {
  bucket = "spartanmarket-s3-bucket"
}

# Add the S3 Bucket Versioning resource
resource "aws_s3_bucket_versioning" "spartanmarket_versioning" {
  bucket = aws_s3_bucket.spartanmarket.bucket
  versioning_configuration {
    status = "Enabled"
  }
}

# SQS Queue for Order Processing
resource "aws_sqs_queue" "order_queue" {
  name = "spartanmarket-order-queue"
}

resource "aws_s3_object" "lambda_image_processing" {
  bucket = aws_s3_bucket.spartanmarket.bucket
  key    = "lambda-functions/image-processing.zip"
  source = "/home/dhruv/lab-cloud-project/lambda/image-processing.zip"  # Correct WSL path
  acl    = "private"
}

# Define Lambda Function for Image Processing (Updated runtime to nodejs18.x)
resource "aws_lambda_function" "image_processing" {
  function_name = "spartanmarket-image-processing"
  s3_bucket     = aws_s3_bucket.spartanmarket.bucket
  s3_key        = "lambda-functions/image-processing.zip"
  handler       = "index.handler"
  runtime       = "nodejs18.x"  

  environment {
    variables = {
      BUCKET_NAME = aws_s3_bucket.spartanmarket.bucket
    }
  }

  role = aws_iam_role.lambda_execution_role.arn
}

# Lambda Execution Role with more specific permissions
resource "aws_iam_role" "lambda_execution_role" {
  name = "lambda_execution_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

# SNS Topic for Alerts
resource "aws_sns_topic" "spartanmarket_alerts" {
  name = "spartanmarket-alerts"
}

# SNS Subscription for Notifications
resource "aws_sns_topic_subscription" "email_subscription" {
  topic_arn = aws_sns_topic.spartanmarket_alerts.arn
  protocol  = "email"
  endpoint  = "ddkhut2207@gmail.com"  
}

# DynamoDB for Session Management and Product Catalog
resource "aws_dynamodb_table" "spartanmarket_sessions" {
  name         = "spartanmarket-sessions"
  hash_key     = "session_id"
  range_key    = "user_id"  
  billing_mode = "PAY_PER_REQUEST"

  attribute {
    name = "session_id"
    type = "S"
  }

  attribute {
    name = "user_id"
    type = "S"
  }

  # Optionally, you can add a Global Secondary Index (GSI) if you need more flexible queries
  global_secondary_index {
    name               = "user_id-index"
    hash_key           = "user_id"
    projection_type    = "ALL"
  }
}

# Define the ElastiCache Subnet Group
resource "aws_elasticache_subnet_group" "spartanmarket_redis_subnet_group" {
  name       = "spartanmarket-redis-subnet-group"
  subnet_ids = aws_subnet.subnet_ids[*].id  
}

# Elasticache (Redis) for Caching
resource "aws_elasticache_cluster" "spartanmarket_redis" {
  cluster_id           = "spartanmarket-redis"
  engine               = "redis"
  node_type            = "cache.t3.micro"
  num_cache_nodes      = 1
  subnet_group_name    = aws_elasticache_subnet_group.spartanmarket_redis_subnet_group.name
  security_group_ids   = [aws_security_group.lb_sg.id]
  parameter_group_name = "default.redis7"  
}

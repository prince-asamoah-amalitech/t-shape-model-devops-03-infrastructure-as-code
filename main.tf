data "aws_caller_identity" "current" {}

# --- Networking -------------------------------------------------------------

resource "aws_vpc" "staging" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name    = "${var.project_tag}-vpc"
    Project = var.project_tag
  }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.staging.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = true

  tags = {
    Name    = "${var.project_tag}-public-subnet"
    Project = var.project_tag
  }

  lifecycle {
    precondition {
      condition     = startswith(var.availability_zone, var.aws_region)
      error_message = "availability_ozne must be inside aws_region (e.g. eu-central-1a in eu-central-1)."
    }
  }
}

resource "aws_internet_gateway" "staging" {
  vpc_id = aws_vpc.staging.id

  tags = {
    Name    = "${var.project_tag}-igw"
    Project = var.project_tag
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.staging.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.staging.id
  }

  tags = {
    Name    = "${var.project_tag}-public-rt"
    Project = var.project_tag
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# --- Security group ----------------------------------------------------------

resource "aws_security_group" "app" {
  name        = "${var.project_tag}-app-sg"
  description = "Kente Retail staging app: SSH and app port, both restricted to allowed_ssh_cidr."
  vpc_id      = aws_vpc.staging.id

  ingress {
    description = "SSH -- restricted, never 0.0.0.0/0"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  ingress {
    description = "App HTTP port"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  egress {
    description = "Unrestricted outbound -- fine for a staging box"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.project_tag}-app-sg"
    Project = var.project_tag
  }
}

# --- IAM: EC2 instance role scoped to its own bucket -------------------------

resource "aws_iam_role" "app" {
  name = "${var.project_tag}-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = {
    Project = var.project_tag
  }
}

resource "aws_iam_role_policy" "app_s3_access" {
  name = "${var.project_tag}-s3-access"
  role = aws_iam_role.app.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowAppBucketReadWrite"
      Effect = "Allow"
      Action = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"]
      Resource = [
        aws_s3_bucket.app_data.arn,
        "${aws_s3_bucket.app_data.arn}/*"
      ]
    }]
  })
}

resource "aws_iam_instance_profile" "app" {
  name = "${var.project_tag}-ec2-profile"
  role = aws_iam_role.app.name
}

# --- Storage -------------------------------------------------------------------

resource "aws_s3_bucket" "app_data" {
  bucket = "${var.project_tag}-${var.bucket_name_suffix}"

  tags = {
    Name    = "${var.project_tag}-${var.bucket_name_suffix}"
    Project = var.project_tag
  }
}

resource "aws_s3_bucket_public_access_block" "app_data" {
  bucket = aws_s3_bucket.app_data.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# --- Compute -------------------------------------------------------------------

resource "aws_instance" "app" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.app.id]
  iam_instance_profile   = aws_iam_instance_profile.app.name
  key_name               = var.key_name

  user_data = <<-EOF
    #!/bin/bash
    set -euxo pipefail
    mkdir -p /opt/staging-app
    cat > /opt/staging-app/index.html <<'HTML'
    <!doctype html><title>Kente Retail staging</title>
    <h1>Kente Retail staging app</h1>
    <p>Provisioned by Terraform.</p>
    HTML
    cat > /etc/systemd/system/staging-app.service <<'UNIT'
    [Unit]
    Description=Kente Retail staging placeholder app
    After=network-online.target

    [Service]
    WorkingDirectory=/opt/staging-app
    ExecStart=/usr/bin/python3 -m http.server 8080
    Restart=always

    [Install]
    WantedBy=multi-user.target
    UNIT
    systemctl daemon-reload
    systemctl enable --now staging-app
  EOF
  tags = {
    Name    = "${var.project_tag}-app"
    Project = var.project_tag
  }
}

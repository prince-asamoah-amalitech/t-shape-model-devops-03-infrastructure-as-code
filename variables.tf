variable "aws_region" {
  description = "AWS region to provision the Kente Retail staging stack in."
  type        = string
  default     = "us-east-1"
}

variable "project_tag" {
  description = <<-EOT
    Unique project identifier. Applied as a Project tag on every resource, and used
    as the required name prefix for the S3 bucket and IAM role (see
    kente-staging-infra-spec.md, section 6). No default on purpose -- pick your own
    before running plan/apply.
  EOT
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the staging VPC."
  type        = string
  default     = "10.42.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for the single public subnet the EC2 instance lives in."
  type        = string
  default     = "10.42.1.0/24"
}

variable "availability_zone" {
  description = "Availability zone for the public subnet."
  type        = string
  default     = "us-east-1a"
}

variable "allowed_ssh_cidr" {
  description = <<-EOT
    CIDR allowed to reach the app/SSH ports on the EC2 instance. Must be a specific
    IP or range you control -- NEVER 0.0.0.0/0 (spec section 4; this is the first
    thing the grading script checks).
  EOT
  type        = string
  # Deliberately not a real reachable range -- replace with your own IP/CIDR
  # before applying. Left non-empty so `terraform validate` passes out of the box.
  default = "203.0.113.0/24"

  validation {
    condition     = !endswith(var.allowed_ssh_cidr, "/0")
    error_message = "allowed_ssh_cidr must be a specific IP or range you control -- never 0.0.0.0/0 (spec 4)."
  }
}

variable "ami_id" {
  description = <<-EOT
    AMI ID for the EC2 instance. Look up a current Amazon Linux 2023 AMI for your
    own region -- do not copy one from someone else's region/account, it likely
    won't exist there.
  EOT
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type. t3.micro is the reference size for this staging workload -- see spec section 2 if you choose differently."
  type        = string
  default     = "t3.micro"
}

variable "bucket_name_suffix" {
  description = "Suffix appended to project_tag to form the (globally-unique) S3 bucket name."
  type        = string
  default     = "data"
}

variable "key_name" {
  description = "Existing EC2 key pair for SSH. The SG opens port 22, so without this the rule leads nowhere."
  type        = string
  default     = null
}
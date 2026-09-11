output "vpc_id" {
  description = "ID of the staging VPC."
  value       = aws_vpc.staging.id
}

output "public_subnet_id" {
  description = "ID of the public subnet."
  value       = aws_subnet.public.id
}

output "internet_gateway_id" {
  description = "ID of the internet gateway."
  value       = aws_internet_gateway.staging.id
}

output "security_group_id" {
  description = "ID of the app security group -- pass this to verify_security_defaults.sh."
  value       = aws_security_group.app.id
}

output "instance_id" {
  description = "ID of the EC2 instance."
  value       = aws_instance.app.id
}

output "instance_public_ip" {
  description = "Public IP of the EC2 instance -- use this for the reachability verification step."
  value       = aws_instance.app.public_ip
}

output "s3_bucket_name" {
  description = "Name of the S3 bucket -- use this for the object-acceptance verification step."
  value       = aws_s3_bucket.app_data.bucket
}

output "iam_role_name" {
  description = "Name of the EC2 IAM role -- pass this to verify_security_defaults.sh."
  value       = aws_iam_role.app.name
}

output "aws_account_id" {
  description = "Account the stack was provisioned in -- include in teardown evidence."
  value       = data.aws_caller_identity.current.account_id
}
output "cluster_id" {
  description = "ECS cluster ID."
  value       = aws_ecs_cluster.this.id
}

output "cluster_name" {
  description = "ECS cluster name."
  value       = aws_ecs_cluster.this.name
}

output "alb_arn" {
  description = "Application Load Balancer ARN."
  value       = aws_lb.this.arn
}

output "alb_dns_name" {
  description = "ALB DNS name. Passed to the security module as the CloudFront origin."
  value       = aws_lb.this.dns_name
}

output "alb_zone_id" {
  description = "ALB hosted zone ID (for Route 53 alias records)."
  value       = aws_lb.this.zone_id
}

output "alb_arn_suffix" {
  description = "ALB ARN suffix for CloudWatch alarm dimensions (wire back into the observability module)."
  value       = aws_lb.this.arn_suffix
}

output "web_target_group_arn" {
  description = "Web service target group ARN."
  value       = aws_lb_target_group.web.arn
}

output "api_internal_url" {
  description = "URL the web tasks reach the api on through Service Connect (http://api:<port>); injected as CNA_API_INTERNAL_URL."
  value       = local.api_internal_url
}

output "service_connect_namespace_arn" {
  description = "Cloud Map HTTP namespace ARN used by ECS Service Connect."
  value       = aws_service_discovery_http_namespace.this.arn
}

output "api_service_name" {
  description = "API ECS service name."
  value       = aws_ecs_service.api.name
}

output "web_service_name" {
  description = "Web ECS service name."
  value       = aws_ecs_service.web.name
}

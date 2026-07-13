locals {
  # Lambda Function URL's own `function_url` attribute is already LocalStack-routable as-is
  # (unlike API Gateway's invoke_url below) — confirmed in Stage B's backend smoke test, a real
  # SigV4-signed curl against this exact host:port succeeded. Real AWS Function URLs are always
  # https with no explicit port; LocalStack's emulation is always http with an explicit :4566.
  # Deriving http-vs-https from the URL's own scheme (rather than var.use_localstack) means this
  # keeps working unchanged once Stage C repoints the same config at real AWS.
  function_url_is_https = startswith(aws_lambda_function_url.backend_stream.function_url, "https://")
  function_url_no_scheme = trimsuffix(
    replace(replace(aws_lambda_function_url.backend_stream.function_url, "https://", ""), "http://", ""),
    "/"
  )
  function_url_host_port = split(":", local.function_url_no_scheme)
  function_url_domain    = local.function_url_host_port[0]
  function_url_port      = length(local.function_url_host_port) > 1 ? tonumber(local.function_url_host_port[1]) : 443
  function_url_protocol  = local.function_url_is_https ? "https-only" : "http-only"

  # Unlike the Function URL above, LocalStack's aws_apigatewayv2_stage.default.invoke_url output
  # mimics real AWS's execute-api.<region>.amazonaws.com shape verbatim — but that hostname does
  # NOT actually resolve/route under LocalStack (verified empirically: the real-shaped host
  # 404s at the DNS/edge level; the wildcard *.execute-api.localhost.localstack.cloud:4566 host,
  # same pattern as ecr.tf's push-image gotcha, is what actually works). So this one has to be
  # reconstructed by hand under LocalStack rather than parsed from the resource's own output.
  api_origin_domain   = var.use_localstack ? "${aws_apigatewayv2_api.this.id}.execute-api.localhost.localstack.cloud" : replace(replace(aws_apigatewayv2_stage.default.invoke_url, "https://", ""), "/", "")
  api_origin_port     = var.use_localstack ? 4566 : 443
  api_origin_protocol = var.use_localstack ? "http-only" : "https-only"
}

resource "aws_cloudfront_origin_access_control" "s3_oac" {
  name                              = "${var.project_name}-${var.environment}-s3-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# CloudFront added OAC support for Lambda Function URL origins in 2023 — this signs requests to
# the streaming Function URL the same way s3_oac signs requests to the S3 bucket, so the URL's
# AWS_IAM auth type (lambda.tf) has something other than "public internet" to actually trust.
# Whether LocalStack's OAC emulation can sign to a Function URL origin specifically was an open
# question carried over from Stage A/B — verified below in the E2E smoke test.
resource "aws_cloudfront_origin_access_control" "lambda_oac" {
  name                              = "${var.project_name}-${var.environment}-lambda-oac"
  origin_access_control_origin_type = "lambda"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# Mirrors the AWS managed "CachingOptimized" policy's actual settings — defined explicitly
# rather than referencing the managed policy by its well-known ID, since that ID is a real-AWS
# account-global constant and its presence under LocalStack's emulation is unconfirmed.
resource "aws_cloudfront_cache_policy" "static_assets" {
  name        = "${var.project_name}-${var.environment}-static-assets"
  min_ttl     = 1
  default_ttl = 86400
  max_ttl     = 31536000

  parameters_in_cache_key_and_forwarded_to_origin {
    enable_accept_encoding_gzip   = true
    enable_accept_encoding_brotli = true

    cookies_config {
      cookie_behavior = "none"
    }
    headers_config {
      header_behavior = "none"
    }
    query_strings_config {
      query_string_behavior = "none"
    }
  }
}

# All three API/Lambda behaviors use this — every one of them is a live backend call, nothing
# under /v1/* is ever cacheable.
resource "aws_cloudfront_cache_policy" "no_cache" {
  name        = "${var.project_name}-${var.environment}-no-cache"
  min_ttl     = 0
  default_ttl = 0
  max_ttl     = 0

  parameters_in_cache_key_and_forwarded_to_origin {
    enable_accept_encoding_gzip   = false
    enable_accept_encoding_brotli = false

    cookies_config {
      cookie_behavior = "none"
    }
    headers_config {
      header_behavior = "none"
    }
    query_strings_config {
      query_string_behavior = "none"
    }
  }
}

# "allExcept: Host" (not "all") — both the API Gateway and Function URL custom origins need
# CloudFront to set Host itself to match the actual origin domain; forwarding the viewer's
# original Host would mismatch what API Gateway/the Function URL expect and, for the OAC-signed
# Function URL specifically, would invalidate the SigV4 signature's host component.
resource "aws_cloudfront_origin_request_policy" "forward_all_except_host" {
  name = "${var.project_name}-${var.environment}-forward-all-except-host"

  cookies_config {
    cookie_behavior = "all"
  }
  headers_config {
    header_behavior = "allExcept"
    headers {
      items = ["Host"]
    }
  }
  query_strings_config {
    query_string_behavior = "all"
  }
}

# The static frontend bucket is a private REST S3 origin (no S3 website hosting, so OAC/HTTPS
# work the normal way) — which means S3 itself does zero extensionless-URL resolution. Next's
# static export writes one *.html file per route (out/login.html, out/chat.html, ...), so a
# browser request for "/login" needs rewriting to "/login.html" before it reaches S3. Whether
# LocalStack's CloudFront emulation runs CloudFront Functions at all is unverified going in —
# checked in the E2E smoke test below.
resource "aws_cloudfront_function" "url_rewrite" {
  name    = "${var.project_name}-${var.environment}-url-rewrite"
  runtime = "cloudfront-js-2.0"
  comment = "Appends .html / index.html to extensionless URIs for the Next.js static export"
  publish = true
  code    = <<-EOT
    function handler(event) {
      var request = event.request;
      var uri = request.uri;

      if (uri.includes('.')) {
        return request;
      }

      request.uri = uri.endsWith('/') ? uri + 'index.html' : uri + '.html';
      return request;
    }
  EOT
}

resource "aws_cloudfront_distribution" "this" {
  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"
  comment             = "${var.project_name}-${var.environment}"
  # Cheapest edge location set (US/Canada/Europe only) — no custom domain or global-latency
  # requirement in this phase; revisit if Stage C ever needs wider geographic reach.
  price_class = "PriceClass_100"

  origin {
    origin_id                = "s3-frontend"
    domain_name              = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.s3_oac.id
  }

  origin {
    origin_id                = "lambda-stream"
    domain_name              = local.function_url_domain
    origin_access_control_id = aws_cloudfront_origin_access_control.lambda_oac.id

    custom_origin_config {
      http_port              = local.function_url_protocol == "http-only" ? local.function_url_port : 80
      https_port             = local.function_url_protocol == "https-only" ? local.function_url_port : 443
      origin_protocol_policy = local.function_url_protocol
      origin_ssl_protocols   = ["TLSv1.2"]

      # CloudFront's own default origin_read_timeout is 30s — almost exactly the CRAG pipeline's
      # measured 31.4s send-message latency (lambda.tf's comment), so leaving this at the default
      # would silently reintroduce the same timeout ceiling the Function URL split (over API
      # Gateway's 29s) was built to avoid, just one hop further out. Raised to match the Lambda
      # functions' own 60s `timeout` (lambda.tf) — confirmed necessary by actually hitting this
      # origin through CloudFront and getting a ReadTimeout at 30s before this fix.
      origin_read_timeout = 60
    }
  }

  # No OAC here — deliberate, matches enterprize-deploy-steps.md's wiring table: HTTP API v2 has
  # no resource-policy equivalent to sign against, so this hop is unauthenticated at the
  # CloudFront-to-origin level (same as the API being reachable directly, which it already is).
  origin {
    origin_id   = "apigw"
    domain_name = local.api_origin_domain

    custom_origin_config {
      http_port              = local.api_origin_protocol == "http-only" ? local.api_origin_port : 80
      https_port             = local.api_origin_protocol == "https-only" ? local.api_origin_port : 443
      origin_protocol_policy = local.api_origin_protocol
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id       = "s3-frontend"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = aws_cloudfront_cache_policy.static_assets.id
    compress               = true

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.url_rewrite.arn
    }
  }

  # Matches send_message's real measured latency (31.4s, Stage B) — routed to the streaming
  # Function URL, not API Gateway, same reasoning as the backend split in lambda.tf: API
  # Gateway's 29s integration timeout would hard-fail this call.
  ordered_cache_behavior {
    path_pattern             = "/v1/sessions/*/messages"
    target_origin_id         = "lambda-stream"
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = aws_cloudfront_cache_policy.no_cache.id
    origin_request_policy_id = aws_cloudfront_origin_request_policy.forward_all_except_host.id
  }

  ordered_cache_behavior {
    path_pattern             = "/v1/sessions/*/stream"
    target_origin_id         = "lambda-stream"
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = aws_cloudfront_cache_policy.no_cache.id
    origin_request_policy_id = aws_cloudfront_origin_request_policy.forward_all_except_host.id
  }

  # Everything else under /v1/* (auth, sessions CRUD, message history) — the API-Gateway-fronted
  # buffered function.
  ordered_cache_behavior {
    path_pattern             = "/v1/*"
    target_origin_id         = "apigw"
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = aws_cloudfront_cache_policy.no_cache.id
    origin_request_policy_id = aws_cloudfront_origin_request_policy.forward_all_except_host.id
  }

  # api/main.py mounts /health deliberately outside the /v1 prefix (standard practice for health
  # checks), so it never matched the /v1/* behavior above and fell through to the S3 frontend
  # origin's default_cache_behavior — a 404 NoSuchKey, not a real health-check failure. Found by
  # cd-lambda.yml's smoke check actually hitting /health through this distribution for the first
  # time; every prior verification session tested /health directly against the origin instead
  # (see completed.md's Phase 15/16 entries), never through CloudFront.
  ordered_cache_behavior {
    path_pattern             = "/health"
    target_origin_id         = "apigw"
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["GET", "HEAD"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = aws_cloudfront_cache_policy.no_cache.id
    origin_request_policy_id = aws_cloudfront_origin_request_policy.forward_all_except_host.id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  # No custom domain this phase (plan.md) — the default *.cloudfront.net cert is all that's
  # needed/available.
  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

# Resource-based policy on the Function URL itself — together with lambda_oac + the Function
# URL's AWS_IAM auth type (lambda.tf), this is the entire perimeter around the streaming path,
# matching enterprize-deploy-steps.md's wiring table.
resource "aws_lambda_permission" "cloudfront_function_url" {
  statement_id           = "AllowCloudFrontServicePrincipal"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.backend_stream.function_name
  principal              = "cloudfront.amazonaws.com"
  source_arn             = aws_cloudfront_distribution.this.arn
  function_url_auth_type = "AWS_IAM"
}

# Real gap found manually testing chat on the first real-AWS deploy (2026-07-13): every request
# through the /v1/sessions/*/stream and /v1/sessions/*/messages behaviors 403'd with Lambda's
# generic Function URL AccessDeniedException, even though OAC, the origin config, and the
# permission above all matched AWS's documented pattern exactly. AWS's own OAC-for-Lambda docs
# (private-content-restricting-access-to-lambda.html) specify granting *two* separate permission
# statements — lambda:InvokeFunctionUrl (above) *and* lambda:InvokeFunction (this one) — this
# second one was missing entirely. The stream Lambda had zero invocations in CloudWatch Logs
# before this fix, confirming CloudFront never got past the permission check to actually reach it.
resource "aws_lambda_permission" "cloudfront_function_url_invoke" {
  statement_id  = "AllowCloudFrontServicePrincipalInvokeFunction"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.backend_stream.function_name
  principal     = "cloudfront.amazonaws.com"
  source_arn    = aws_cloudfront_distribution.this.arn
}

#!/bin/bash
# Cloud CV - Local Development Script
# SRE/DevOps Engineer Portfolio

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
FRONTEND_DIR="$PROJECT_ROOT/frontend"
LOCALSTACK_IMAGE="${LOCALSTACK_IMAGE:-localstack/localstack:4.14.0}"
LOCALSTACK_SERVICES="${LOCALSTACK_SERVICES:-s3,dynamodb}"
LOCALSTACK_ENABLE_DOCKER="${LOCALSTACK_ENABLE_DOCKER:-0}"

# Default values
ACTION="start"

# Functions
log() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Cloud CV Local Development Script

OPTIONS:
    start               Start LocalStack development environment (default)
    stop                Stop LocalStack development environment
    restart             Restart LocalStack development environment
    upload              Upload frontend files to S3
    status              Show LocalStack status
    -h, --help          Show this help message

EXAMPLES:
    $0                  # Start LocalStack (default)
    $0 start            # Start LocalStack
    $0 stop             # Stop LocalStack
    $0 restart          # Restart LocalStack
    $0 upload           # Upload frontend files to S3
    $0 status           # Show status

EOF
}

check_dependencies() {
    log "Checking dependencies..."
    
    local deps=("docker" "aws" "curl")
    local missing=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing+=("$dep")
        fi
    done
    
    if [ ${#missing[@]} -ne 0 ]; then
        error "Missing dependencies: ${missing[*]}"
    fi
    
    success "All dependencies found"
}

get_docker_socket_path() {
    local docker_host
    docker_host="${DOCKER_HOST:-$(docker context inspect "$(docker context show)" --format '{{ (index .Endpoints "docker").Host }}' 2>/dev/null || true)}"
    
    if [[ "$docker_host" =~ ^unix://(.+)$ ]]; then
        echo "${BASH_REMATCH[1]}"
    fi
}

start_localstack() {
    log "Starting LocalStack..."
    
    local docker_socket
    local docker_run_args=()
    local -a docker_cmd
    
    # Check if LocalStack is already running
    if docker ps --format "table {{.Names}}" | grep -q "^localstack$"; then
        warning "LocalStack is already running"
        return
    fi
    
    # Clean up any existing container (running or stopped)
    if docker ps -a --format "table {{.Names}}" | grep -q "^localstack$"; then
        log "Removing existing LocalStack container..."
        docker rm -f localstack 2>/dev/null || true
    fi
    
    if [ "$LOCALSTACK_ENABLE_DOCKER" = "1" ]; then
        docker_socket="$(get_docker_socket_path)"
        
        if [ -n "$docker_socket" ] && [ -S "$docker_socket" ]; then
            docker_run_args+=("-v" "$docker_socket:/var/run/docker.sock")
            docker_run_args+=("-e" "DOCKER_HOST=unix:///var/run/docker.sock")
        else
            warning "Docker socket could not be detected; continuing without Lambda container support"
        fi
    fi
    
    docker_cmd=(
        docker run -d
        --name localstack
        -p 4566:4566
        -p 4510-4559:4510-4559
        -e SERVICES="$LOCALSTACK_SERVICES"
        -e DEBUG=1
    )
    
    if [ ${#docker_run_args[@]} -gt 0 ]; then
        docker_cmd+=("${docker_run_args[@]}")
    fi
    
    docker_cmd+=("$LOCALSTACK_IMAGE")
    
    # Start LocalStack container
    "${docker_cmd[@]}"
    
    # Wait for LocalStack to be ready
    log "Waiting for LocalStack to be ready..."
    local max_attempts=30
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if curl -s http://localhost:4566/_localstack/health > /dev/null 2>&1; then
            success "LocalStack is ready!"
            return
        fi
        
        log "Attempt $attempt/$max_attempts - LocalStack not ready yet..."
        sleep 2
        ((attempt++))
    done
    
    error "LocalStack failed to start after $max_attempts attempts"
}

setup_aws_credentials() {
    log "Setting up AWS credentials for LocalStack..."
    
    export AWS_ACCESS_KEY_ID=test
    export AWS_SECRET_ACCESS_KEY=test
    export AWS_DEFAULT_REGION=us-east-1
    export AWS_ENDPOINT_URL=http://localhost:4566
    
    success "AWS credentials configured for LocalStack"
}

create_resources() {
    log "Creating AWS resources..."
    
    # Create S3 bucket
    log "Creating S3 bucket..."
    aws s3 mb s3://cloud-cv-local --endpoint-url=http://localhost:4566 || warning "Bucket may already exist"
    
    # Create DynamoDB table
    log "Creating DynamoDB table..."
    aws dynamodb create-table \
        --table-name visitor-counter \
        --attribute-definitions AttributeName=id,AttributeType=S \
        --key-schema AttributeName=id,KeyType=HASH \
        --billing-mode PAY_PER_REQUEST \
        --endpoint-url=http://localhost:4566 || warning "Table may already exist"
    
    # Initialize visitor count
    log "Initializing visitor count..."
    aws dynamodb put-item \
        --table-name visitor-counter \
        --item '{"id":{"S":"visitor-count"},"count":{"N":"0"}}' \
        --endpoint-url=http://localhost:4566 || warning "Item may already exist"
    
    success "AWS resources created"
}

upload_frontend() {
    log "Uploading frontend files..."
    
    # Upload frontend files
    aws s3 cp "$FRONTEND_DIR/index.html" s3://cloud-cv-local/ --content-type "text/html" --endpoint-url=http://localhost:4566
    aws s3 cp "$FRONTEND_DIR/styles.css" s3://cloud-cv-local/ --content-type "text/css" --endpoint-url=http://localhost:4566
    aws s3 cp "$FRONTEND_DIR/script.js" s3://cloud-cv-local/ --content-type "application/javascript" --endpoint-url=http://localhost:4566
    
    # Upload CV if it exists
    if [ -f "$PROJECT_ROOT/cv.pdf" ]; then
        aws s3 cp "$PROJECT_ROOT/cv.pdf" s3://cloud-cv-local/ --content-type "application/pdf" --endpoint-url=http://localhost:4566
    fi
    
    success "Frontend files uploaded"
}

upload_files() {
    log "Uploading files to S3..."
    
    # Check if LocalStack is running
    if ! docker ps --format "table {{.Names}}" | grep -q "^localstack$"; then
        error "LocalStack is not running. Please start it first with: $0 start"
    fi
    
    # Setup AWS credentials
    setup_aws_credentials
    
    # Upload frontend files
    upload_frontend
    
    success "Files uploaded successfully!"
    echo ""
    echo "🌐 Your updated Cloud CV is accessible at:"
    echo "   http://localhost:4566/cloud-cv-local/index.html"
}

show_urls() {
    log "Cloud CV is now running!"
    echo ""
    echo "📋 Access URLs:"
    echo "   🌐 Website: http://localhost:4566/cloud-cv-local/index.html"
    echo "   📁 S3 Browser: http://localhost:4566/cloud-cv-local/"
    echo "   🔍 LocalStack Health: http://localhost:4566/_localstack/health"
    echo ""
    echo "📋 Available services:"
    echo "   ✅ S3: http://localhost:4566"
    echo "   ✅ DynamoDB: http://localhost:4566"
    echo "   ✅ Lambda: http://localhost:4566"
    echo "   ✅ API Gateway: http://localhost:4566"
    echo ""
    echo "🚀 Your Cloud CV is accessible at:"
    echo "   http://localhost:4566/cloud-cv-local/index.html"
}

stop_localstack() {
    log "Stopping LocalStack..."
    
    if docker ps --format "table {{.Names}}" | grep -q "^localstack$"; then
        docker stop localstack
        docker rm localstack
        success "LocalStack stopped and removed"
    else
        warning "LocalStack is not running"
    fi
}

show_status() {
    log "Checking LocalStack status..."
    
    if docker ps --format "table {{.Names}}" | grep -q "^localstack$"; then
        success "LocalStack is running"
        echo ""
        echo "📋 Container details:"
        docker ps | grep localstack
        echo ""
        echo "📋 Health check:"
        if curl -s http://localhost:4566/_localstack/health > /dev/null 2>&1; then
            success "LocalStack is healthy"
        else
            warning "LocalStack is running but not responding"
        fi
        echo ""
        echo "🌐 Access URLs:"
        echo "   Website: http://localhost:4566/cloud-cv-local/index.html"
        echo "   Health: http://localhost:4566/_localstack/health"
    else
        warning "LocalStack is not running"
        echo ""
        echo "To start LocalStack, run:"
        echo "   $0 start"
    fi
}

start_environment() {
    log "Starting Cloud CV local development environment..."
    
    # Run setup steps
    check_dependencies
    start_localstack
    setup_aws_credentials
    create_resources
    upload_frontend
    show_urls
    
    success "Local development environment is ready!"
}

main() {
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            start)
                ACTION="start"
                shift
                ;;
            stop)
                ACTION="stop"
                shift
                ;;
            restart)
                ACTION="restart"
                shift
                ;;
            upload)
                ACTION="upload"
                shift
                ;;
            status)
                ACTION="status"
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                ;;
        esac
    done
    
    # Execute action
    case $ACTION in
        start)
            start_environment
            ;;
        stop)
            stop_localstack
            ;;
        restart)
            stop_localstack
            sleep 2
            start_environment
            ;;
        upload)
            upload_files
            ;;
        status)
            show_status
            ;;
        *)
            error "Unknown action: $ACTION"
            ;;
    esac
}

# Run main function
main "$@"

# Docker image configuration
IMAGE_NAME := psyb0t/claudebox
TAG := latest

.PHONY: build build-minimal build-all clean help

# Default target
all: build

# Build the full image
build:
	docker build --target full -t $(IMAGE_NAME):$(TAG) .

# Build the minimal image
build-minimal:
	docker build --target minimal -t $(IMAGE_NAME):$(TAG)-minimal .

# Build both
build-all: build build-minimal

# Clean up images
clean:
	docker rmi $(IMAGE_NAME):$(TAG) || true
	docker rmi $(IMAGE_NAME):$(TAG)-minimal || true

# Show available targets
help:
	@echo "Available targets:"
	@echo "  build          - Build the full Docker image"
	@echo "  build-minimal  - Build the minimal Docker image"
	@echo "  build-all      - Build both images"
	@echo "  clean          - Remove built images"
	@echo "  help           - Show this help message"

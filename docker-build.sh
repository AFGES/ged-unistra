#!/bin/bash

# Script de build et déploiement pour WebDAV CAS Proxy
# Usage: ./docker-build.sh [--build-only] [--push] [--no-cache]

set -e  # Arrêter en cas d'erreur

# Variables de configuration
IMAGE_NAME="webdav-cas-proxy"
IMAGE_TAG="0.1.0"
REGISTRY=""  # Ajouter votre registry si nécessaire (ex: "registry.example.com/")
FULL_IMAGE_NAME="${REGISTRY}${IMAGE_NAME}:${IMAGE_TAG}"

# Couleurs pour l'affichage
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Fonctions d'affichage
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Analyse des arguments
BUILD_ONLY=false
PUSH=false
NO_CACHE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --build-only)
            BUILD_ONLY=true
            shift
            ;;
        --push)
            PUSH=true
            shift
            ;;
        --no-cache)
            NO_CACHE="--no-cache"
            shift
            ;;
        *)
            log_error "Argument inconnu: $1"
            exit 1
            ;;
    esac
done

# Vérifications préliminaires
log_info "Vérification des prérequis..."

if ! command -v docker &> /dev/null; then
    log_error "Docker n'est pas installé ou n'est pas dans le PATH"
    exit 1
fi

if ! docker info &> /dev/null; then
    log_error "Docker daemon n'est pas démarré"
    exit 1
fi

# Build de l'image
log_info "Construction de l'image Docker: ${FULL_IMAGE_NAME}"
log_info "Options de build: ${NO_CACHE}"

docker build ${NO_CACHE} \
    --tag "${FULL_IMAGE_NAME}" \
    --tag "${IMAGE_NAME}:latest" \
    --label "build.date=$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
    --label "build.version=${IMAGE_TAG}" \
    .

if [ $? -eq 0 ]; then
    log_success "Image construite avec succès: ${FULL_IMAGE_NAME}"
else
    log_error "Échec de la construction de l'image"
    exit 1
fi

# Affichage des informations sur l'image
log_info "Taille de l'image:"
docker images "${IMAGE_NAME}" --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}\t{{.CreatedAt}}"

if [ "${BUILD_ONLY}" = true ]; then
    log_info "Build terminé (--build-only spécifié)"
    exit 0
fi

# Test de l'image
log_info "Test de démarrage de l'image..."
CONTAINER_ID=$(docker run -d -p 3001:3000 "${FULL_IMAGE_NAME}")

sleep 5

if docker ps | grep -q "${CONTAINER_ID}"; then
    log_success "Conteneur démarré avec succès"
    
    # Test du healthcheck
    log_info "Test du endpoint de santé..."
    if curl -f -s http://localhost:3001/admin/cache/stats > /dev/null; then
        log_success "Endpoint de santé accessible"
    else
        log_warning "Endpoint de santé non accessible (normal si pas d'auth)"
    fi
    
    docker stop "${CONTAINER_ID}" > /dev/null
    docker rm "${CONTAINER_ID}" > /dev/null
    log_success "Test terminé avec succès"
else
    log_error "Échec du démarrage du conteneur"
    docker logs "${CONTAINER_ID}"
    docker rm "${CONTAINER_ID}" > /dev/null
    exit 1
fi

# Push vers le registry (optionnel)
if [ "${PUSH}" = true ]; then
    if [ -z "${REGISTRY}" ]; then
        log_warning "Aucun registry configuré, skip du push"
    else
        log_info "Push vers le registry: ${REGISTRY}"
        docker push "${FULL_IMAGE_NAME}"
        docker push "${REGISTRY}${IMAGE_NAME}:latest"
        log_success "Image poussée vers le registry"
    fi
fi

log_success "Script terminé avec succès!"
log_info "Pour démarrer le service: docker-compose up -d"
#!/bin/bash

# =============================================================================
# Скрипт очистки ресурсов Yandex Functions
# =============================================================================

set -e

# =============================================================================
# НАСТРОЙКИ - ДОЛЖНЫ СОВПАДАТЬ С deploy.sh
# =============================================================================

APP_NAME="auth-api"

# Автоматически генерируемые имена на основе APP_NAME
LOCKBOX_NAME="${APP_NAME}-keys"
SERVICE_ACCOUNT_NAME="${APP_NAME}-function-sa"
FUNCTION_NAME="${APP_NAME}"

# =============================================================================
# ЦВЕТА ДЛЯ ВЫВОДА
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

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

get_profile_info() {
    log_info "Получение информации из профиля yc..."
    
    # Получаем cloud-id и folder-id из профиля
    CLOUD_ID=$(yc config get cloud-id 2>/dev/null)
    FOLDER_ID=$(yc config get folder-id 2>/dev/null)
    
    if [ -z "$CLOUD_ID" ]; then
        log_error "Cloud ID не задан в профиле yc. Выполните: yc config set cloud-id <your-cloud-id>"
        exit 1
    fi
    
    if [ -z "$FOLDER_ID" ]; then
        log_error "Folder ID не задан в профиле yc. Выполните: yc config set folder-id <your-folder-id>"
        exit 1
    fi
    
    # Получаем имена облака и папки
    CLOUD_NAME=$(yc resource-manager cloud get "$CLOUD_ID" --format json 2>/dev/null | jq -r '.name // "неизвестно"')
    FOLDER_NAME=$(yc resource-manager folder get "$FOLDER_ID" --format json 2>/dev/null | jq -r '.name // "неизвестно"')
    
    log_success "Информация профиля получена"
}

check_requirements() {
    log_info "Проверка требований..."
    
    if ! command -v yc &> /dev/null; then
        log_error "Yandex Cloud CLI не установлен. Установите его с https://cloud.yandex.ru/docs/cli/quickstart"
        exit 1
    fi
    
    if ! command -v jq &> /dev/null; then
        log_error "jq не установлен. Установите его: brew install jq (macOS) или apt-get install jq (Ubuntu)"
        exit 1
    fi
    
    log_success "Все требования выполнены"
}

# =============================================================================
# ФУНКЦИИ ОЧИСТКИ
# =============================================================================

find_and_delete_function() {
    log_info "Поиск и удаление функции $FUNCTION_NAME..."

    FUNCTION_ID=$(yc serverless function get "$FUNCTION_NAME" --folder-id "$FOLDER_ID" --format json 2>/dev/null | jq -r '.id // empty')

    if [ ! -z "$FUNCTION_ID" ]; then
        yc serverless function delete "$FUNCTION_ID" > /dev/null 2>&1
        log_success "Функция удалена: $FUNCTION_ID"
    else
        log_warning "Функция $FUNCTION_NAME не найдена"
    fi
}

find_and_delete_service_account() {
    log_info "Поиск и удаление сервисного аккаунта $SERVICE_ACCOUNT_NAME..."

    SERVICE_ACCOUNT_ID=$(yc iam service-account get "$SERVICE_ACCOUNT_NAME" --folder-id "$FOLDER_ID" --format json 2>/dev/null | jq -r '.id // empty')

    if [ ! -z "$SERVICE_ACCOUNT_ID" ]; then
        yc iam service-account delete "$SERVICE_ACCOUNT_ID" > /dev/null 2>&1
        log_success "Сервисный аккаунт удален: $SERVICE_ACCOUNT_ID"
    else
        log_warning "Сервисный аккаунт $SERVICE_ACCOUNT_NAME не найден"
    fi
}

find_and_delete_lockbox() {
    log_info "Поиск и удаление Lockbox секрета $LOCKBOX_NAME..."

    LOCKBOX_ID=$(yc lockbox secret get "$LOCKBOX_NAME" --folder-id "$FOLDER_ID" --format json 2>/dev/null | jq -r '.id // empty')

    if [ ! -z "$LOCKBOX_ID" ]; then
        yc lockbox secret delete "$LOCKBOX_ID" > /dev/null 2>&1
        log_success "Lockbox секрет удален: $LOCKBOX_ID"
    else
        log_warning "Lockbox секрет $LOCKBOX_NAME не найден"
    fi
}

# =============================================================================
# ОСНОВНОЙ СКРИПТ
# =============================================================================

# Проверяем требования
check_requirements

# Получаем информацию из профиля
get_profile_info

echo -e "${RED}"
echo "============================================================================="
echo "  Очистка ресурсов Yandex Functions"
echo "============================================================================="
echo -e "${NC}"

echo -e "${BLUE}Информация о очистке:${NC}"
echo "• Cloud ID: $CLOUD_ID"
echo "• Cloud Name: $CLOUD_NAME"
echo "• Folder ID: $FOLDER_ID"
echo "• Folder Name: $FOLDER_NAME"
echo "• Имя приложения: $APP_NAME"
echo ""
echo -e "${YELLOW}Будут удалены следующие ресурсы:${NC}"
echo "• Lockbox секрет: $LOCKBOX_NAME"
echo "• Сервисный аккаунт: $SERVICE_ACCOUNT_NAME"
echo "• Yandex Function: $FUNCTION_NAME"
echo ""

read -p "Вы уверены, что хотите удалить все ресурсы? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log_info "Отменено пользователем"
    exit 0
fi

echo ""

# Удаляем ресурсы в обратном порядке
find_and_delete_function
find_and_delete_service_account
find_and_delete_lockbox

echo ""
echo -e "${GREEN}"
echo "============================================================================="
echo "  Очистка ресурсов завершена! 🧹"
echo "============================================================================="
echo -e "${NC}"

echo -e "${BLUE}Удалены ресурсы из:${NC}"
echo "• Cloud: $CLOUD_NAME ($CLOUD_ID)"
echo "• Folder: $FOLDER_NAME ($FOLDER_ID)"
echo ""

log_success "Все ресурсы успешно удалены!"

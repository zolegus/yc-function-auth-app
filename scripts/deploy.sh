#!/bin/bash

# =============================================================================
# Скрипт развертывания Yandex Functions с авторизацией через Lockbox
# =============================================================================

set -e  # Остановка при первой ошибке

# =============================================================================
# НАСТРОЙКИ - ИЗМЕНИТЕ ПОД ВАШИ ПАРАМЕТРЫ
# =============================================================================

APP_NAME="auth-api"

# Автоматически генерируемые имена на основе APP_NAME
LOCKBOX_NAME="${APP_NAME}-keys"
SERVICE_ACCOUNT_NAME="${APP_NAME}-function-sa"
FUNCTION_NAME="${APP_NAME}"

# API ключи для тестирования (в формате key:user:role)
API_KEYS="abc123:john:admin,def456:jane:user,ghi789:bob:user"

# =============================================================================
# ЦВЕТА ДЛЯ ВЫВОДА
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# =============================================================================
# ФУНКЦИИ УТИЛИТЫ
# =============================================================================

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

show_deployment_info() {
    echo -e "${BLUE}"
    echo "============================================================================="
    echo "  Развертывание Yandex Functions с авторизацией через Lockbox"
    echo "============================================================================="
    echo -e "${NC}"

    echo -e "${BLUE}Информация о развертывании:${NC}"
    echo "• Cloud ID: $CLOUD_ID"
    echo "• Cloud Name: $CLOUD_NAME"
    echo "• Folder ID: $FOLDER_ID"
    echo "• Folder Name: $FOLDER_NAME"
    echo "• Имя приложения: $APP_NAME"
    echo ""
    echo -e "${YELLOW}Будут созданы следующие ресурсы:${NC}"
    echo "• Lockbox секрет: $LOCKBOX_NAME"
    echo "• Сервисный аккаунт: $SERVICE_ACCOUNT_NAME"
    echo "• Yandex Function: $FUNCTION_NAME"
    echo ""
    echo -e "${YELLOW}API ключи для тестирования:${NC}"
    echo "• abc123 - john (admin)"
    echo "• def456 - jane (user)"
    echo "• ghi789 - bob (user)"
    echo ""

    read -p "Подтвердите развертывание? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Развертывание отменено пользователем"
        exit 0
    fi
    echo ""
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

    if ! command -v curl &> /dev/null; then
        log_error "curl не установлен"
        exit 1
    fi

    if [ ! -f "src/handler.py" ]; then
        log_error "Файл src/handler.py не найден. Убедитесь, что вы запускаете скрипт из корневой директории проекта"
        exit 1
    fi

    log_success "Все требования выполнены"
}

# =============================================================================
# ОСНОВНЫЕ ФУНКЦИИ
# =============================================================================

create_lockbox() {
    log_info "Создание Lockbox секрета..."

    # Создаем секрет
    LOCKBOX_ID=$(yc lockbox secret create \
        --name "$LOCKBOX_NAME" \
        --description "API ключи для приложения $APP_NAME" \
        --folder-id "$FOLDER_ID" \
        --format json | jq -r '.id')

    if [ -z "$LOCKBOX_ID" ]; then
        log_error "Не удалось создать Lockbox секрет"
        exit 1
    fi

    # Добавляем версию с ключами
    LOCKBOX_VERSION_ID=$(yc lockbox secret add-version \
        --id "$LOCKBOX_ID" \
        --payload '[{"key":"api_keys","text_value":"'$API_KEYS'"}]' \
        --format json | jq -r '.id')

    if [ -z "$LOCKBOX_VERSION_ID" ]; then
        log_error "Не удалось создать версию Lockbox секрета"
        exit 1
    fi

    log_success "Lockbox секрет создан: $LOCKBOX_ID (версия: $LOCKBOX_VERSION_ID)"
}

create_service_account() {
    log_info "Создание сервисного аккаунта..."

    # Создаем сервисный аккаунт
    SERVICE_ACCOUNT_ID=$(yc iam service-account create \
        --name "$SERVICE_ACCOUNT_NAME" \
        --description "Сервисный аккаунт для функции $FUNCTION_NAME" \
        --folder-id "$FOLDER_ID" \
        --format json | jq -r '.id')

    if [ -z "$SERVICE_ACCOUNT_ID" ]; then
        log_error "Не удалось создать сервисный аккаунт"
        exit 1
    fi

    # Назначаем роль для чтения секретов
    yc lockbox secret add-access-binding \
        --id "$LOCKBOX_ID" \
        --role lockbox.payloadViewer \
        --subject serviceAccount:"$SERVICE_ACCOUNT_ID" > /dev/null

    log_success "Сервисный аккаунт создан: $SERVICE_ACCOUNT_ID"
}

create_function() {
    log_info "Создание Yandex Function..."

    # Создаем функцию
    FUNCTION_ID=$(yc serverless function create \
        --name "$FUNCTION_NAME" \
        --folder-id "$FOLDER_ID" \
        --format json | jq -r '.id')

    if [ -z "$FUNCTION_ID" ]; then
        log_error "Не удалось создать функцию"
        exit 1
    fi

    # Создаем версию функции
    log_info "Развертывание кода функции..."

    yc serverless function version create \
        --function-id "$FUNCTION_ID" \
        --runtime python312 \
        --entrypoint handler.handler \
        --memory 128m \
        --execution-timeout 30s \
        --source-path src \
        --service-account-id "$SERVICE_ACCOUNT_ID" \
        --secret environment-variable=API_KEYS,id="$LOCKBOX_ID",version-id="$LOCKBOX_VERSION_ID",key=api_keys > /dev/null

    log_success "Функция создана и развернута: $FUNCTION_ID"
}

make_function_public() {
    log_info "Публикация функции..."

    # Делаем функцию публичной
    yc serverless function allow-unauthenticated-invoke "$FUNCTION_ID" > /dev/null

    # Получаем публичный URL
    FUNCTION_URL=$(yc serverless function get "$FUNCTION_ID" --format json | jq -r '.http_invoke_url')

    log_success "Функция опубликована: $FUNCTION_URL"
}

test_function() {
    log_info "Тестирование функции..."

    # Ждем немного для инициализации
    sleep 5

    echo ""
    log_info "=== ТЕСТИРОВАНИЕ АВТОРИЗАЦИИ ==="

    # Тест 1: Корректный admin ключ
    echo ""
    log_info "Тест 1: Авторизация admin пользователя (john)"
    RESPONSE=$(curl -s -H "x-api-key: abc123" "$FUNCTION_URL")
    echo "Ответ: $RESPONSE"

    # Тест 2: Маршрут /profile для admin
    echo ""
    log_info "Тест 2: Профиль admin пользователя"
    RESPONSE=$(curl -s -H "x-api-key: abc123" "$FUNCTION_URL?path=/profile")
    echo "Ответ: $RESPONSE"

    # Тест 3: Маршрут /admin для admin
    echo ""
    log_info "Тест 3: Доступ к /admin для admin пользователя"
    RESPONSE=$(curl -s -H "x-api-key: abc123" "$FUNCTION_URL?path=/admin")
    echo "Ответ: $RESPONSE"

    # Тест 4: Корректный user ключ
    echo ""
    log_info "Тест 4: Авторизация user пользователя (jane)"
    RESPONSE=$(curl -s -H "x-api-key: def456" "$FUNCTION_URL?path=/profile")
    echo "Ответ: $RESPONSE"

    # Тест 5: user пытается получить доступ к /admin
    echo ""
    log_info "Тест 5: Попытка user получить доступ к /admin (должна быть отклонена)"
    RESPONSE=$(curl -s -H "x-api-key: def456" "$FUNCTION_URL?path=/admin")
    echo "Ответ: $RESPONSE"

    # Тест 6: Неверный ключ
    echo ""
    log_info "Тест 6: Неверный API ключ (должен быть отклонен)"
    RESPONSE=$(curl -s -H "x-api-key: invalid123" "$FUNCTION_URL")
    echo "Ответ: $RESPONSE"

    echo ""
    log_success "Тестирование завершено!"
}

cleanup_on_error() {
    log_error "Произошла ошибка при развертывании. Запустите скрипт очистки:"
    echo "  ./scripts/cleanup.sh"
}

# =============================================================================
# ОСНОВНОЙ СКРИПТ
# =============================================================================

# Проверяем требования
check_requirements

# Получаем информацию из профиля
get_profile_info

# Показываем информацию и запрашиваем подтверждение
show_deployment_info

# Устанавливаем обработчик ошибок
trap cleanup_on_error ERR

# Выполняем основные шаги
create_lockbox
create_service_account
create_function
make_function_public

# Тестируем функцию
test_function

# =============================================================================
# ФИНАЛЬНЫЙ ВЫВОД
# =============================================================================

echo ""
echo -e "${GREEN}"
echo "============================================================================="
echo "  Развертывание успешно завершено! 🎉"
echo "============================================================================="
echo -e "${NC}"

echo -e "${BLUE}Информация о развертывании:${NC}"
echo "• Cloud: $CLOUD_NAME ($CLOUD_ID)"
echo "• Folder: $FOLDER_NAME ($FOLDER_ID)"
echo "• Function URL: $FUNCTION_URL"
echo "• Lockbox ID: $LOCKBOX_ID"
echo "• Service Account ID: $SERVICE_ACCOUNT_ID"
echo "• Function ID: $FUNCTION_ID"
echo ""

echo -e "${YELLOW}Примеры использования:${NC}"
echo ""
echo "1. Базовая авторизация:"
echo "   curl -H \"x-api-key: abc123\" \"$FUNCTION_URL\""
echo ""
echo "2. Доступ к профилю:"
echo "   curl -H \"x-api-key: abc123\" \"$FUNCTION_URL?path=/profile\""
echo ""
echo "3. Доступ к админке (только для admin):"
echo "   curl -H \"x-api-key: abc123\" \"$FUNCTION_URL?path=/admin\""
echo ""
echo "4. Доступ обычного пользователя:"
echo "   curl -H \"x-api-key: def456\" \"$FUNCTION_URL?path=/profile\""
echo ""

echo -e "${BLUE}API ключи для тестирования:${NC}"
echo "• abc123 - john (admin) - полный доступ"
echo "• def456 - jane (user) - доступ к /profile"
echo "• ghi789 - bob (user) - доступ к /profile"
echo ""

echo -e "${YELLOW}Для очистки ресурсов запустите:${NC}"
echo "  ./scripts/cleanup.sh"
echo ""

log_success "Развертывание завершено успешно!"

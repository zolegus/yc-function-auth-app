import json
import os


def handler(event, context):
    """Функция с встроенной авторизацией через статические ключи"""

    # Получаем API ключ из заголовков
    headers = event.get("headers", {})
    # В Yandex Functions заголовки в Pascal-Case формате
    api_key = headers.get("Authorization") or headers.get("X-Api-Key")

    if api_key and api_key.startswith("Bearer "):
        api_key = api_key[7:]

    # Проверяем авторизацию
    auth_result = check_authorization(api_key)
    if not auth_result["authorized"]:
        return {
            "statusCode": 403,
            "body": json.dumps({"error": "Unauthorized"}),
            "headers": {"Content-Type": "application/json"},
        }

    # Основная логика API
    return handle_api_request(event, auth_result["user_info"])


def check_authorization(api_key):
    """Проверка авторизации по статическим ключам из Lockbox"""
    if not api_key:
        return {"authorized": False}

    valid_keys_str = os.environ.get("API_KEYS", "")
    valid_keys = {}

    for pair in valid_keys_str.split(","):
        parts = pair.split(":")
        if len(parts) >= 2:
            key = parts[0].strip()
            user = parts[1].strip()
            role = parts[2].strip() if len(parts) > 2 else "user"
            valid_keys[key] = {"user_id": user, "role": role}

    if api_key in valid_keys:
        return {"authorized": True, "user_info": valid_keys[api_key]}

    return {"authorized": False}


def handle_api_request(event, user_info):
    """Основная логика API после успешной авторизации"""
    method = event.get("httpMethod", "GET")
    path = event.get("path", "/")
    
    # Для удобного тестирования: получаем путь из query параметра или JSON тела
    query_params = event.get("queryStringParameters") or {}
    if query_params.get("path"):
        path = query_params["path"]
    
    # Если есть JSON тело, пытаемся получить путь оттуда
    body = event.get("body", "")
    if body:
        try:
            body_data = json.loads(body)
            if body_data.get("path"):
                path = body_data["path"]
        except:
            pass  # Игнорируем ошибки парсинга JSON

    if path == "/profile":
        return {
            "statusCode": 200,
            "body": json.dumps(
                {
                    "user_id": user_info["user_id"],
                    "role": user_info["role"],
                    "message": "Profile data",
                }
            ),
            "headers": {"Content-Type": "application/json"},
        }

    elif path == "/admin" and user_info["role"] != "admin":
        return {
            "statusCode": 403,
            "body": json.dumps({"error": "Admin access required"}),
            "headers": {"Content-Type": "application/json"},
        }

    elif path == "/admin":
        return {
            "statusCode": 200,
            "body": json.dumps({"message": "Admin panel access granted"}),
            "headers": {"Content-Type": "application/json"},
        }

    return {
        "statusCode": 200,
        "body": json.dumps(
            {
                "message": "API is working",
                "user": user_info["user_id"],
                "method": method,
                "path": path,
            }
        ),
        "headers": {"Content-Type": "application/json"},
    }

import base64
import json
from typing import Any, Optional

from Crypto.Cipher import AES
from Crypto.Util.Padding import pad, unpad

from app.config import settings


class CryptoError(Exception):
    """加密/解密错误异常"""
    pass


def _to_bytes(name: str, value: Optional[str]) -> bytes:
    """将配置项转换为 16 字节的 bytes（AES-128 要求密钥和 IV 必须是 16 字节）

    Args:
        name: 配置项名称（如 "aes_key" 或 "aes_iv"）
        value: 自定义值（为 None 时从 settings 读取）

    Returns:
        16 字节的 bytes

    Raises:
        CryptoError: 长度不为 16 字节时抛出
    """
    raw = (value if value is not None else getattr(settings, name)).encode("utf-8")
    if len(raw) != 16:
        raise CryptoError(f"{name} must be 16 bytes, got {len(raw)}")
    return raw


def decrypt_b64(cipher_b64: str, key: Optional[str] = None, iv: Optional[str] = None) -> Any:
    """解密 base64 编码的 AES-CBC 加密数据

    Args:
        cipher_b64: base64 编码的密文（可含空格/换行）
        key: 自定义 AES 密钥（为 None 时从 settings 读取）
        iv: 自定义 AES IV（为 None 时从 settings 读取）

    Returns:
        解密后的 Python 对象（通常是 dict）

    Raises:
        CryptoError: base64 解码失败、解密失败、JSON 解析失败时抛出
    """
    cleaned = "".join(str(cipher_b64).split())  # 去除所有空白字符（空格、换行等）
    if not cleaned:
        raise CryptoError("empty ciphertext")
    try:
        raw = base64.b64decode(cleaned)  # base64 解码为原始密文
    except Exception as e:
        raise CryptoError(f"base64 decode failed: {e}") from e
    cipher = AES.new(_to_bytes("aes_key", key), AES.MODE_CBC, _to_bytes("aes_iv", iv))  # 创建 AES-CBC 解密器
    try:
        plain = unpad(cipher.decrypt(raw), AES.block_size)  # 解密并去除 PKCS7 填充
    except Exception as e:
        raise CryptoError(f"decrypt/unpad failed: {e}") from e
    try:
        return json.loads(plain.decode("utf-8"))  # 解码为 JSON
    except Exception as e:
        raise CryptoError(f"json decode failed: {e}") from e


def encrypt_to_b64(obj: Any, key: Optional[str] = None, iv: Optional[str] = None) -> str:
    """将 Python 对象加密为 base64 编码的字符串（AES-CBC + PKCS7 填充）

    Args:
        obj: 要加密的 Python 对象（需可 JSON 序列化）
        key: 自定义 AES 密钥（为 None 时从 settings 读取）
        iv: 自定义 AES IV（为 None 时从 settings 读取）

    Returns:
        base64 编码的加密密文（不含换行）
    """
    raw = json.dumps(obj, ensure_ascii=False).encode("utf-8")  # 序列化为 JSON 并转为 UTF-8 字节
    cipher = AES.new(_to_bytes("aes_key", key), AES.MODE_CBC, _to_bytes("aes_iv", iv))  # 创建 AES-CBC 加密器
    return base64.b64encode(cipher.encrypt(pad(raw, AES.block_size))).decode("utf-8")  # 加密、base64 编码

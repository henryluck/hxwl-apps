"""测试加密解密：验证加密后能正确解密、处理带换行的Base64、以及各种异常情况。"""
import pytest

from app.crypto import CryptoError, decrypt_b64, encrypt_to_b64


def test_round_trip_dict():
    """验证加密与解密的往返一致性。"""
    obj = {"data": {"userId": 100123, "newUser": True}}
    cipher = encrypt_to_b64(obj)
    assert decrypt_b64(cipher) == obj


def test_round_trip_with_whitespace_in_base64():
    """验证解密能正确处理带换行符的Base64密文。"""
    obj = {"a": 1}
    cipher = encrypt_to_b64(obj)
    # 插入换行与空格模拟 76 字符折行
    folded = "\n".join(cipher[i:i + 32] for i in range(0, len(cipher), 32))
    assert decrypt_b64(folded) == obj


def test_decrypt_invalid_base64_raises():
    """验证无效Base64输入会抛出CryptoError。"""
    with pytest.raises(CryptoError):
        decrypt_b64("!!!not base64!!!")


def test_decrypt_wrong_key_raises():
    """验证使用错误密钥解密会抛出CryptoError。"""
    cipher = encrypt_to_b64({"a": 1}, key="7JkKJHW075iEdXbH")
    with pytest.raises(CryptoError):
        decrypt_b64(cipher, key="0000000000000000")


def test_decrypt_empty_raises():
    """验证空或仅含空白字符的输入会抛出CryptoError。"""
    with pytest.raises(CryptoError):
        decrypt_b64("   ")

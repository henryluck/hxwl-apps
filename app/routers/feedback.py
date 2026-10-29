"""意见反馈路由：解密客户端 AES 请求，将反馈写入本地 SQLite。

不走天枢转发（意见反馈为本地存储），但仍复用统一的 parse_request 解密信封：
- Authorization 头 → adhead（设备信息）
- body → data（用户输入：type/content/contact/appVersion...）
"""
from fastapi import APIRouter, Depends, Request  # Request 须在无默认参数位置

from app.config import settings
from app.deps import ParsedRequest, parse_request
from app.errors import success_response
from app.storage import save_feedback

router = APIRouter()


@router.post("/api/v1/support/feedback")
async def save(request: Request, req: ParsedRequest = Depends(parse_request)):
    """保存意见反馈：业务字段取自 data，设备信息取自 adhead，落库后返回标准信封。"""
    db_path = getattr(request.app.state, "feedback_db_path", None) or settings.feedback_db_path
    row_id = await save_feedback(req.adhead, req.data, req.client_ip, db_path=db_path)
    return success_response({"id": row_id}, "反馈已提交")

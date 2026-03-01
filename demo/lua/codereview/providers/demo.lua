local M = {}

M.name = "demo"

-- 3 mock PRs
local reviews = {
  {
    id = 42, title = "Refactor auth middleware", author = "alice",
    source_branch = "refactor/auth-middleware", target_branch = "main",
    state = "opened", web_url = "https://github.com/demo/showcase/pull/42",
    description = "Extract token validation into a utility module.\n\nThis PR:\n- Moves JWT logic out of the middleware\n- Adds proper error types\n- Adds unit tests",
    pipeline_status = "success",
    base_sha = "abc1234", head_sha = "def5678", sha = "def5678",
    approved_by = {}, approvals_required = 1, merge_status = "can_be_merged",
  },
  {
    id = 38, title = "Add dark mode support", author = "bob",
    source_branch = "feat/dark-mode", target_branch = "main",
    state = "opened", web_url = "https://github.com/demo/showcase/pull/38",
    description = "Adds system-preference-aware dark mode toggle.",
    pipeline_status = "running",
    base_sha = "111aaaa", head_sha = "222bbbb", sha = "222bbbb",
    approved_by = {}, approvals_required = 1,
  },
  {
    id = 35, title = "Fix pagination off-by-one", author = "charlie",
    source_branch = "fix/pagination", target_branch = "main",
    state = "opened", web_url = "https://github.com/demo/showcase/pull/35",
    description = "Fixes the off-by-one error on the last page.",
    pipeline_status = "success",
    base_sha = "333cccc", head_sha = "444dddd", sha = "444dddd",
    approved_by = { "alice" }, approvals_required = 1,
  },
}

-- Diffs for PR #42 (the one we demo)
local diffs_42 = {
  {
    new_path = "src/middleware/auth.ts",
    old_path = "src/middleware/auth.ts",
    new_file = false, renamed_file = false, deleted_file = false,
    diff = table.concat({
      "@@ -1,18 +1,15 @@",
      "-import { Request, Response, NextFunction } from 'express';",
      "-import jwt from 'jsonwebtoken';",
      "+import { Request, Response, NextFunction } from 'express';",
      "+import { verifyToken, extractTokenFromHeader } from '../utils/token';",
      " ",
      "-const SECRET = process.env.JWT_SECRET || 'dev-secret';",
      "-",
      " export function authMiddleware(req: Request, res: Response, next: NextFunction) {",
      "-  const token = req.headers.authorization?.split(' ')[1];",
      "+  const token = extractTokenFromHeader(req.headers.authorization);",
      "   if (!token) {",
      "-    return res.status(401).json({ error: 'No token provided' });",
      "+    return res.status(401).json({ error: 'Authentication required' });",
      "   }",
      "-  try {",
      "-    const decoded = jwt.verify(token, SECRET);",
      "-    req.user = decoded;",
      "-    next();",
      "-  } catch {",
      "-    return res.status(403).json({ error: 'Invalid token' });",
      "+",
      "+  const result = verifyToken(token);",
      "+  if (!result.valid) {",
      "+    return res.status(403).json({ error: result.error });",
      "   }",
      "+",
      "+  req.user = result.payload;",
      "+  next();",
      " }",
    }, "\n"),
  },
  {
    new_path = "src/utils/token.ts",
    old_path = "src/utils/token.ts",
    new_file = true, renamed_file = false, deleted_file = false,
    diff = table.concat({
      "@@ -0,0 +1,27 @@",
      "+import jwt from 'jsonwebtoken';",
      "+",
      "+const SECRET = process.env.JWT_SECRET;",
      "+",
      "+if (!SECRET) {",
      "+  throw new Error('JWT_SECRET must be set');",
      "+}",
      "+",
      "+export function extractTokenFromHeader(header?: string): string | null {",
      "+  if (!header) return null;",
      "+  const [scheme, token] = header.split(' ');",
      "+  return scheme === 'Bearer' ? token : null;",
      "+}",
      "+",
      "+export interface TokenResult {",
      "+  valid: boolean;",
      "+  payload?: jwt.JwtPayload;",
      "+  error?: string;",
      "+}",
      "+",
      "+export function verifyToken(token: string): TokenResult {",
      "+  try {",
      "+    const payload = jwt.verify(token, SECRET!) as jwt.JwtPayload;",
      "+    return { valid: true, payload };",
      "+  } catch (err) {",
      "+    return { valid: false, error: (err as Error).message };",
      "+  }",
      "+}",
    }, "\n"),
  },
  {
    new_path = "src/routes/login.ts",
    old_path = "src/routes/login.ts",
    new_file = false, renamed_file = false, deleted_file = false,
    diff = table.concat({
      "@@ -1,5 +1,5 @@",
      " import { Router } from 'express';",
      "-import jwt from 'jsonwebtoken';",
      "+import { createToken } from '../utils/token';",
      " import { validateCredentials } from '../services/auth';",
      " ",
      " const router = Router();",
      "@@ -10,5 +10,5 @@",
      "   const user = await validateCredentials(email, password);",
      "   if (!user) {",
      "     return res.status(401).json({ error: 'Invalid credentials' });",
      "   }",
      "-  const token = jwt.sign({ id: user.id, email: user.email }, process.env.JWT_SECRET!, { expiresIn: '24h' });",
      "+  const token = createToken({ id: user.id, email: user.email });",
      "   res.json({ token, user: { id: user.id, email: user.email } });",
      " });",
    }, "\n"),
  },
  {
    new_path = "tests/middleware/auth.test.ts",
    old_path = "tests/middleware/auth.test.ts",
    new_file = true, renamed_file = false, deleted_file = false,
    diff = table.concat({
      "@@ -0,0 +1,28 @@",
      "+import { describe, it, expect, vi } from 'vitest';",
      "+import { authMiddleware } from '../../src/middleware/auth';",
      "+",
      "+describe('authMiddleware', () => {",
      "+  it('returns 401 when no authorization header', async () => {",
      "+    const req = { headers: {} } as any;",
      "+    const res = { status: vi.fn().mockReturnThis(), json: vi.fn() } as any;",
      "+    const next = vi.fn();",
      "+",
      "+    authMiddleware(req, res, next);",
      "+",
      "+    expect(res.status).toHaveBeenCalledWith(401);",
      "+    expect(next).not.toHaveBeenCalled();",
      "+  });",
      "+",
      "+  it('calls next with valid token', async () => {",
      "+    const req = {",
      "+      headers: { authorization: 'Bearer valid-test-token' },",
      "+    } as any;",
      "+    const res = { status: vi.fn().mockReturnThis(), json: vi.fn() } as any;",
      "+    const next = vi.fn();",
      "+",
      "+    authMiddleware(req, res, next);",
      "+",
      "+    expect(next).toHaveBeenCalled();",
      "+    expect(req.user).toBeDefined();",
      "+  });",
      "+});",
    }, "\n"),
  },
}

-- Existing discussions on PR #42
local discussions_42 = {
  {
    id = "disc-001",
    resolved = true,
    notes = {
      {
        id = 101, author = "bob", body = "Should we keep the fallback `'dev-secret'` for local development?",
        created_at = "2026-02-27T09:15:00Z", system = false, resolvable = true,
        resolved = true, resolved_by = "alice",
        position = { new_path = "src/middleware/auth.ts", old_path = "src/middleware/auth.ts", new_line = 4, old_line = nil },
      },
      {
        id = 102, author = "alice", body = "No — the new `token.ts` throws at startup if `JWT_SECRET` isn't set, which is safer. Resolving.",
        created_at = "2026-02-27T09:22:00Z", system = false, resolvable = false,
        resolved = false, resolved_by = nil, position = nil,
      },
    },
  },
  {
    id = "disc-002",
    resolved = false,
    notes = {
      {
        id = 201, author = "charlie",
        body = "Nice extraction! One thought — `extractTokenFromHeader` could support multiple schemes in the future (e.g., `Basic` for service-to-service).",
        created_at = "2026-02-27T14:05:00Z", system = false, resolvable = true,
        resolved = false, resolved_by = nil,
        position = { new_path = "src/utils/token.ts", old_path = "src/utils/token.ts", new_line = 9, old_line = nil },
      },
    },
  },
}

-- Full file content for "view full file" (Ctrl+F)
local file_contents = {
  ["src/middleware/auth.ts"] = table.concat({
    "import { Request, Response, NextFunction } from 'express';",
    "import { verifyToken, extractTokenFromHeader } from '../utils/token';",
    "",
    "export function authMiddleware(req: Request, res: Response, next: NextFunction) {",
    "  const token = extractTokenFromHeader(req.headers.authorization);",
    "  if (!token) {",
    "    return res.status(401).json({ error: 'Authentication required' });",
    "  }",
    "",
    "  const result = verifyToken(token);",
    "  if (!result.valid) {",
    "    return res.status(403).json({ error: result.error });",
    "  }",
    "",
    "  req.user = result.payload;",
    "  next();",
    "}",
  }, "\n"),
  ["src/utils/token.ts"] = table.concat({
    "import jwt from 'jsonwebtoken';",
    "",
    "const SECRET = process.env.JWT_SECRET;",
    "",
    "if (!SECRET) {",
    "  throw new Error('JWT_SECRET must be set');",
    "}",
    "",
    "export function extractTokenFromHeader(header?: string): string | null {",
    "  if (!header) return null;",
    "  const [scheme, token] = header.split(' ');",
    "  return scheme === 'Bearer' ? token : null;",
    "}",
    "",
    "export interface TokenResult {",
    "  valid: boolean;",
    "  payload?: jwt.JwtPayload;",
    "  error?: string;",
    "}",
    "",
    "export function verifyToken(token: string): TokenResult {",
    "  try {",
    "    const payload = jwt.verify(token, SECRET!) as jwt.JwtPayload;",
    "    return { valid: true, payload };",
    "  } catch (err) {",
    "    return { valid: false, error: (err as Error).message };",
    "  }",
    "}",
  }, "\n"),
  ["src/routes/login.ts"] = table.concat({
    "import { Router } from 'express';",
    "import { createToken } from '../utils/token';",
    "import { validateCredentials } from '../services/auth';",
    "",
    "const router = Router();",
    "",
    "router.post('/login', async (req, res) => {",
    "  const { email, password } = req.body;",
    "",
    "  const user = await validateCredentials(email, password);",
    "  if (!user) {",
    "    return res.status(401).json({ error: 'Invalid credentials' });",
    "  }",
    "  const token = createToken({ id: user.id, email: user.email });",
    "  res.json({ token, user: { id: user.id, email: user.email } });",
    "});",
  }, "\n"),
  ["tests/middleware/auth.test.ts"] = table.concat({
    "import { describe, it, expect, vi } from 'vitest';",
    "import { authMiddleware } from '../../src/middleware/auth';",
    "",
    "describe('authMiddleware', () => {",
    "  it('returns 401 when no authorization header', async () => {",
    "    const req = { headers: {} } as any;",
    "    const res = { status: vi.fn().mockReturnThis(), json: vi.fn() } as any;",
    "    const next = vi.fn();",
    "",
    "    authMiddleware(req, res, next);",
    "",
    "    expect(res.status).toHaveBeenCalledWith(401);",
    "    expect(next).not.toHaveBeenCalled();",
    "  });",
    "",
    "  it('calls next with valid token', async () => {",
    "    const req = {",
    "      headers: { authorization: 'Bearer valid-test-token' },",
    "    } as any;",
    "    const res = { status: vi.fn().mockReturnThis(), json: vi.fn() } as any;",
    "    const next = vi.fn();",
    "",
    "    authMiddleware(req, res, next);",
    "",
    "    expect(next).toHaveBeenCalled();",
    "    expect(req.user).toBeDefined();",
    "  });",
    "});",
  }, "\n"),
}

function M.list_reviews(_client, _ctx, _opts)
  return reviews, nil
end

function M.get_review(_client, _ctx, id)
  for _, r in ipairs(reviews) do
    if r.id == id then return r, nil end
  end
  return nil, "Not found"
end

function M.get_diffs(_client, _ctx, review)
  if review.id == 42 then return diffs_42, nil end
  return {}, nil
end

-- Track posted comments so get_discussions returns them
local next_id = 900
local posted_comments = {}

function M.get_discussions(_client, _ctx, review)
  if review.id == 42 then
    local discs = {}
    for _, d in ipairs(discussions_42) do table.insert(discs, d) end
    for _, d in ipairs(posted_comments) do table.insert(discs, d) end
    return discs, nil
  end
  return {}, nil
end

function M.get_file_content(_client, _ctx, _ref, path)
  return file_contents[path] or "", nil
end

function M.get_current_user(_client, _ctx)
  return "demo-user", nil
end

function M.post_comment(_client, _ctx, _review, body, position)
  position = position or {}
  next_id = next_id + 1
  -- Normalize position like a real API: keep new_line for additions/context,
  -- old_line only for deletion-only lines
  local norm_pos = {
    new_path = position.new_path,
    old_path = position.old_path,
    new_line = position.new_line,
    old_line = position.new_line and nil or position.old_line,
  }
  table.insert(posted_comments, {
    id = "disc-posted-" .. next_id,
    resolved = false,
    notes = {{
      id = next_id, author = "demo-user", body = body,
      created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"), system = false,
      resolvable = true, resolved = false,
      position = norm_pos,
    }},
  })
  return { id = next_id }, nil
end

function M.post_range_comment(_client, _ctx, _review, _opts)
  next_id = next_id + 1
  return { id = next_id }, nil
end

function M.reply_to_discussion(_client, _ctx, _review, _disc_id, _body)
  next_id = next_id + 1
  return { id = next_id }, nil
end

function M.create_draft_comment(_client, _ctx, review, opts)
  opts = opts or {}
  next_id = next_id + 1
  table.insert(posted_comments, {
    id = "disc-posted-" .. next_id,
    resolved = false,
    notes = {{
      id = next_id, author = "demo-user", body = opts.body or "",
      created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"), system = false,
      resolvable = true, resolved = false,
      position = { new_path = opts.path, old_path = opts.path, new_line = opts.line },
    }},
  })
  return { id = next_id }, nil
end

-- Other write stubs
function M.edit_note(_client, _ctx, _review, _note_id, _body) return { id = 903 }, nil end
function M.delete_note(_client, _ctx, _review, _note_id) return true, nil end
function M.resolve_discussion(_client, _ctx, _review, _disc_id, _resolved) return true, nil end
function M.approve(_client, _ctx, _review) return true, nil end
function M.unapprove(_client, _ctx, _review) return true, nil end
function M.merge(_client, _ctx, _review) return true, nil end
function M.close(_client, _ctx, _review) return true, nil end
function M.create_review(_client, _ctx, _opts)
  return { data = { iid = 99, web_url = "https://gitlab.com/acme/api-server/-/merge_requests/99" } }, nil
end
function M.get_pending_review_drafts(_client, _ctx, _review) return {}, nil end
function M.get_draft_notes(_client, _ctx, _review, _review_id) return {}, nil end
function M.delete_draft_note(_client, _ctx, _review, _note_id) return true, nil end
function M.publish_review(_client, _ctx, _review, _review_id, _body) return true, nil end

return M

-- Rules and bot for the 3x4 mini-shogi. Pure logic: no drawing, no view models.
--
-- Squares are numbered 0..11 as row * 3 + col, row 0 being the player's back
-- row. `board` is 1-based storage, so square s lives at board[s + 1]. A cell
-- holds 0 when empty, +kind for a player piece and -kind for a bot piece.
--
-- generateMoves(state)      -> every legal move for the side to move
-- applyMove(state, move)    -> a new state; the input is left untouched
-- checkEnd(state, ...)      -> who won after a move, and why
-- botChoose(state, level)   -> the bot's move, in one call
-- positionKey(state)        -> the string compared by the repetition rule

local M = {}

M.KING = 1
M.ROOK = 2
M.BISHOP = 3
M.PAWN = 4
M.GOLD = 5

M.PLAYER = 1
M.BOT = -1

export type Move = { kind: string, from: number, to: number, piece: number }

export type State = {
    board: { number },
    -- Pieces in hand, indexed by kind.
    handPlayer: { number },
    handBot: { number },
    turn: number,
}

export type Ending = { winner: number, reason: string }

type Delta = { x: number, y: number }

local function d(x: number, y: number): Delta
    return { x = x, y = y }
end

local ORTHO = { d(0, 1), d(1, 0), d(0, -1), d(-1, 0) }
local DIAG = { d(1, 1), d(-1, 1), d(1, -1), d(-1, -1) }
local ALL = { d(0, 1), d(1, 0), d(0, -1), d(-1, 0), d(1, 1), d(-1, 1), d(1, -1), d(-1, -1) }
local PAWN_STEP = { d(0, 1) }
local GOLD_STEP = { d(0, 1), d(1, 0), d(-1, 0), d(0, -1), d(1, 1), d(-1, 1) }

local STEPS: { { Delta } } = { ALL, ORTHO, DIAG, PAWN_STEP, GOLD_STEP }

local INFINITY = 1000000
local VALUE: { number } = { 0, 3, 3, 1, 3 }

function M.newState(): State
    local board = table.create(12, 0)
    board[1] = M.ROOK
    board[2] = M.KING
    board[3] = M.BISHOP
    board[5] = M.PAWN
    board[8] = -M.PAWN
    board[10] = -M.BISHOP
    board[11] = -M.KING
    board[12] = -M.ROOK
    return {
        board = board,
        handPlayer = table.create(5, 0),
        handBot = table.create(5, 0),
        turn = M.PLAYER,
    }
end

local function copy(state: State): State
    return {
        board = table.clone(state.board),
        handPlayer = table.clone(state.handPlayer),
        handBot = table.clone(state.handBot),
        turn = state.turn,
    }
end

M.copy = copy

local function handOf(state: State, side: number): { number }
    if side == M.PLAYER then
        return state.handPlayer
    end
    return state.handBot
end

M.handOf = handOf

local function sign(n: number): number
    if n > 0 then
        return 1
    elseif n < 0 then
        return -1
    end
    return 0
end

local function farRow(side: number): number
    if side == M.PLAYER then
        return 3
    end
    return 0
end

M.farRow = farRow

function M.rowOf(square: number): number
    return math.floor(square / 3)
end

function M.colOf(square: number): number
    return square % 3
end

-- Appends every square the piece on `from` can step to.
local function targets(board: { number }, from: number): { number }
    local result = {}
    local cell = board[from + 1]
    if cell == 0 then
        return result
    end
    local side = sign(cell)
    local col = from % 3
    local row = math.floor(from / 3)
    for _, step in STEPS[math.abs(cell)] do
        local c = col + step.x * side
        local r = row + step.y * side
        if c >= 0 and c <= 2 and r >= 0 and r <= 3 then
            local to = r * 3 + c
            if sign(board[to + 1]) ~= side then
                table.insert(result, to)
            end
        end
    end
    return result
end

function M.generateMoves(state: State): { Move }
    local moves: { Move } = {}
    local side = state.turn
    local board = state.board
    for square = 0, 11 do
        if sign(board[square + 1]) == side then
            for _, to in targets(board, square) do
                table.insert(moves, { kind = 'move', from = square, to = to, piece = math.abs(board[square + 1]) })
            end
        end
    end
    local hand = handOf(state, side)
    for kind = M.ROOK, M.PAWN do
        if hand[kind] > 0 then
            for square = 0, 11 do
                if board[square + 1] == 0 then
                    table.insert(moves, { kind = 'drop', from = -1, to = square, piece = kind })
                end
            end
        end
    end
    return moves
end

-- True when any piece of `bySide` could step onto `square`.
function M.isAttacked(board: { number }, square: number, bySide: number): boolean
    for from = 0, 11 do
        if sign(board[from + 1]) == bySide then
            for _, to in targets(board, from) do
                if to == square then
                    return true
                end
            end
        end
    end
    return false
end

function M.findKing(board: { number }, side: number): number
    local wanted = M.KING * side
    for square = 0, 11 do
        if board[square + 1] == wanted then
            return square
        end
    end
    return -1
end

export type Undo = { move: Move, moved: number, captured: number, side: number }

-- Plays a move on `state` itself and returns what undo needs. The search uses
-- this pair so that it does not copy a table per node.
local function make(state: State, move: Move): Undo
    local side = state.turn
    local board = state.board
    local captured = 0
    local moved = 0
    if move.kind == 'drop' then
        moved = move.piece * side
        board[move.to + 1] = moved
        local hand = handOf(state, side)
        hand[move.piece] -= 1
    else
        moved = board[move.from + 1]
        captured = board[move.to + 1]
        board[move.from + 1] = 0
        local placed = moved
        if math.abs(moved) == M.PAWN and M.rowOf(move.to) == farRow(side) then
            placed = M.GOLD * side
        end
        board[move.to + 1] = placed
        if captured ~= 0 then
            local kind = math.abs(captured)
            if kind == M.GOLD then
                kind = M.PAWN
            end
            -- A captured king is recorded too: the game is over at that point,
            -- and the search undoes it straight away.
            local hand = handOf(state, side)
            hand[kind] += 1
        end
    end
    state.turn = -side
    return { move = move, moved = moved, captured = captured, side = side }
end

local function undo(state: State, u: Undo)
    local board = state.board
    local move = u.move
    state.turn = u.side
    if move.kind == 'drop' then
        board[move.to + 1] = 0
        local hand = handOf(state, u.side)
        hand[move.piece] += 1
    else
        board[move.from + 1] = u.moved
        board[move.to + 1] = u.captured
        if u.captured ~= 0 then
            local kind = math.abs(u.captured)
            if kind == M.GOLD then
                kind = M.PAWN
            end
            local hand = handOf(state, u.side)
            hand[kind] -= 1
        end
    end
end

function M.applyMove(state: State, move: Move): State
    local next = copy(state)
    make(next, move)
    return next
end

function M.positionKey(state: State): string
    return table.concat(state.board, ',')
        .. '|'
        .. table.concat(state.handPlayer, ',')
        .. '|'
        .. table.concat(state.handBot, ',')
        .. '|'
        .. tostring(state.turn)
end

-- Winner check for the side that has just moved, in the order the spec fixes:
-- a captured king first, then a surviving try by the other side.
local function winnerAfter(state: State, mover: number, captured: number): number
    if math.abs(captured) == M.KING then
        return mover
    end
    local other = -mover
    local king = M.findKing(state.board, other)
    if king >= 0 and M.rowOf(king) == farRow(other) then
        return other
    end
    return 0
end

-- `state` is the position after the move, so state.turn is the opponent of
-- the mover. `repeats` is how many times this position has now occurred.
function M.checkEnd(state: State, captured: number, repeats: number): Ending?
    local mover = -state.turn
    local winner = winnerAfter(state, mover, captured)
    if winner ~= 0 then
        local reason = 'try'
        if math.abs(captured) == M.KING then
            reason = 'capture'
        end
        return { winner = winner, reason = reason }
    end
    if repeats >= 3 then
        return { winner = 0, reason = 'repetition' }
    end
    return nil
end

-- Static score from the bot's point of view.
local function evaluate(state: State): number
    local score = 0
    local board = state.board
    for square = 0, 11 do
        local cell = board[square + 1]
        if cell ~= 0 then
            score -= VALUE[math.abs(cell)] * sign(cell) * 10
        end
    end
    for kind = M.ROOK, M.PAWN do
        score += VALUE[kind] * state.handBot[kind] * 8
        score -= VALUE[kind] * state.handPlayer[kind] * 8
    end
    local botKing = M.findKing(board, M.BOT)
    local playerKing = M.findKing(board, M.PLAYER)
    if botKing >= 0 then
        if M.isAttacked(board, botKing, M.PLAYER) then
            score -= 6
        else
            score += (3 - M.rowOf(botKing)) * 2
        end
    end
    if playerKing >= 0 then
        if M.isAttacked(board, playerKing, M.BOT) then
            score += 6
        else
            score -= M.rowOf(playerKing) * 2
        end
    end
    return score
end

M.evaluate = evaluate

-- Fisher-Yates, so that equally scored moves do not always play the same way.
local function shuffle(moves: { Move })
    for i = #moves, 2, -1 do
        local j = math.random(1, i)
        moves[i], moves[j] = moves[j], moves[i]
    end
end

type Search = { nodes: number, budget: number }

-- Negamax-free minimax: the bot maximises, the player minimises. Returns a
-- score, with faster wins scoring higher through `ply`.
local function search(state: State, depth: number, alpha: number, beta: number, ply: number, s: Search): number
    s.nodes += 1
    if depth == 0 or s.nodes >= s.budget then
        return evaluate(state)
    end
    local maximizing = state.turn == M.BOT
    local best = if maximizing then -INFINITY else INFINITY
    for _, move in M.generateMoves(state) do
        local mover = state.turn
        local u = make(state, move)
        local winner = winnerAfter(state, mover, u.captured)
        local score = 0
        if winner == M.BOT then
            score = INFINITY - 1 - ply
        elseif winner == M.PLAYER then
            score = -INFINITY + 1 + ply
        else
            score = search(state, depth - 1, alpha, beta, ply + 1, s)
        end
        undo(state, u)
        if maximizing then
            best = math.max(best, score)
            alpha = math.max(alpha, best)
        else
            best = math.min(best, score)
            beta = math.min(beta, best)
        end
        if beta <= alpha then
            break
        end
    end
    return best
end

-- Searches every root move to `depth`. Returns the best move, or nil if the
-- node budget ran out, in which case a partial result would be misleading.
function M.searchRoot(root: State, depth: number, budget: number): Move?
    local state = copy(root)
    local moves = M.generateMoves(state)
    shuffle(moves)
    local s: Search = { nodes = 0, budget = budget }
    local best: Move? = nil
    local bestScore = -INFINITY - 1
    for _, move in moves do
        local u = make(state, move)
        local winner = winnerAfter(state, M.BOT, u.captured)
        local score = 0
        if winner == M.BOT then
            score = INFINITY
        elseif winner == M.PLAYER then
            score = -INFINITY
        else
            score = search(state, depth - 1, bestScore, INFINITY, 1, s)
        end
        undo(state, u)
        if score > bestScore then
            bestScore = score
            best = move
        end
        if s.nodes >= s.budget then
            return nil
        end
    end
    return best
end

function M.easyMove(root: State): Move
    local state = copy(root)
    local moves = M.generateMoves(state)
    shuffle(moves)
    local safe: { Move } = {}
    for _, move in moves do
        local u = make(state, move)
        local winner = winnerAfter(state, M.BOT, u.captured)
        local king = M.findKing(state.board, M.BOT)
        local exposed = king >= 0 and M.isAttacked(state.board, king, M.PLAYER)
        undo(state, u)
        if winner == M.BOT then
            return move
        end
        if not exposed and winner == 0 then
            table.insert(safe, move)
        end
    end
    if #safe > 0 then
        return safe[1]
    end
    return moves[1]
end

-- Search depth per level; hard deepens as far as its budget allows.
M.DEPTH_MEDIUM = 3
M.DEPTH_HARD = 6
M.NODE_BUDGET = 20000

-- Whole-move convenience, used by tests. The game spreads the same search
-- over frames instead so that it never stalls a frame.
function M.botChoose(state: State, level: string): Move
    if level == 'easy' then
        return M.easyMove(state)
    end
    local maxDepth = if level == 'medium' then M.DEPTH_MEDIUM else M.DEPTH_HARD
    local best: Move? = nil
    for depth = 1, maxDepth do
        local found = M.searchRoot(state, depth, M.NODE_BUDGET)
        if found == nil then
            break
        end
        best = found
    end
    if best ~= nil then
        return best
    end
    return M.easyMove(state)
end

return M

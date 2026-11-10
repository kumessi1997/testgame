-- Rule checks from section 13 of the gameplay document.
-- Run headless with `rive . --test`.
local E = require('engine')

local function empty(): E.State
    local s = E.newState()
    s.board = table.create(12, 0)
    return s
end

local function square(col: number, row: number): number
    return (row - 1) * 3 + col
end

local function hasMove(moves: { E.Move }, from: number, to: number): boolean
    for _, m in moves do
        if m.kind == 'move' and m.from == from and m.to == to then
            return true
        end
    end
    return false
end

local function targetsFrom(state: E.State, from: number): number
    local count = 0
    for _, m in E.generateMoves(state) do
        if m.from == from then
            count += 1
        end
    end
    return count
end

local function moveOf(from: number, to: number, piece: number): E.Move
    return { kind = 'move', from = from, to = to, piece = piece }
end

function setup(test: Tester)
    test.group('opening', function()
        test.case('player has exactly the four documented moves', function(expect)
            local moves = E.generateMoves(E.newState())
            expect(#moves).is(4)
            expect(hasMove(moves, square(0, 1), square(0, 2))).is(true)
            expect(hasMove(moves, square(1, 1), square(0, 2))).is(true)
            expect(hasMove(moves, square(1, 1), square(2, 2))).is(true)
            expect(hasMove(moves, square(1, 2), square(1, 3))).is(true)
        end)
    end)

    test.group('movement', function()
        test.case('a centre king has eight steps', function(expect)
            local s = empty()
            s.board[square(1, 2) + 1] = E.KING
            expect(targetsFrom(s, square(1, 2))).is(8)
        end)
        test.case('a pawn only steps forward, and bot forward is down', function(expect)
            local s = empty()
            s.board[square(1, 2) + 1] = E.PAWN
            expect(targetsFrom(s, square(1, 2))).is(1)
            local b = empty()
            b.turn = E.BOT
            b.board[square(1, 3) + 1] = -E.PAWN
            expect(hasMove(E.generateMoves(b), square(1, 3), square(1, 2))).is(true)
        end)
        test.case('gold has six steps and no backward diagonal', function(expect)
            local s = empty()
            s.board[square(1, 2) + 1] = E.GOLD
            local moves = E.generateMoves(s)
            expect(#moves).is(6)
            expect(hasMove(moves, square(1, 2), square(0, 1))).is(false)
            expect(hasMove(moves, square(1, 2), square(2, 1))).is(false)
        end)
        test.case('a piece cannot take its own side', function(expect)
            local s = empty()
            s.board[square(0, 1) + 1] = E.ROOK
            s.board[square(0, 2) + 1] = E.PAWN
            expect(hasMove(E.generateMoves(s), square(0, 1), square(0, 2))).is(false)
        end)
    end)

    test.group('capture, drop and promotion', function()
        test.case('a pawn entering the far row promotes', function(expect)
            local s = empty()
            s.board[square(0, 3) + 1] = E.PAWN
            local after = E.applyMove(s, moveOf(square(0, 3), square(0, 4), E.PAWN))
            expect(after.board[square(0, 4) + 1]).is(E.GOLD)
        end)
        test.case('a captured gold goes to hand as a pawn', function(expect)
            local s = empty()
            s.board[square(0, 1) + 1] = E.ROOK
            s.board[square(0, 2) + 1] = -E.GOLD
            local after = E.applyMove(s, moveOf(square(0, 1), square(0, 2), E.ROOK))
            expect(after.handPlayer[E.PAWN]).is(1)
            expect(after.handPlayer[E.GOLD]).is(0)
        end)
        test.case('drops only reach empty squares', function(expect)
            local s = E.newState()
            s.handPlayer[E.ROOK] = 1
            local drops = 0
            for _, m in E.generateMoves(s) do
                if m.kind == 'drop' then
                    drops += 1
                    expect(s.board[m.to + 1]).is(0)
                end
            end
            expect(drops).is(4)
        end)
        test.case('a pawn dropped on the far row stays a pawn', function(expect)
            local s = empty()
            s.handPlayer[E.PAWN] = 1
            local after = E.applyMove(s, { kind = 'drop', from = -1, to = square(0, 4), piece = E.PAWN })
            expect(after.board[square(0, 4) + 1]).is(E.PAWN)
            expect(after.handPlayer[E.PAWN]).is(0)
        end)
        test.case('applyMove leaves its input alone', function(expect)
            local s = E.newState()
            E.applyMove(s, moveOf(square(1, 2), square(1, 3), E.PAWN))
            expect(s.board[square(1, 3) + 1]).is(-E.PAWN)
            expect(s.turn).is(E.PLAYER)
        end)
    end)

    test.group('game end', function()
        test.case('capturing the king wins at once', function(expect)
            local s = empty()
            s.board[square(0, 1) + 1] = E.ROOK
            s.board[square(0, 2) + 1] = -E.KING
            s.board[square(2, 1) + 1] = E.KING
            local after = E.applyMove(s, moveOf(square(0, 1), square(0, 2), E.ROOK))
            local ending = E.checkEnd(after, -E.KING, 1)
            expect(ending ~= nil).is(true)
            if ending then
                expect(ending.winner).is(E.PLAYER)
                expect(ending.reason).is('capture')
            end
        end)
        test.case('a king reaching the far row has not won yet', function(expect)
            local s = empty()
            s.board[square(0, 3) + 1] = E.KING
            s.board[square(2, 2) + 1] = -E.KING
            local after = E.applyMove(s, moveOf(square(0, 3), square(0, 4), E.KING))
            expect(E.checkEnd(after, 0, 1) == nil).is(true)
        end)
        test.case('the try wins once the opponent has replied', function(expect)
            local s = empty()
            s.board[square(0, 4) + 1] = E.KING
            s.board[square(2, 3) + 1] = -E.KING
            s.turn = E.BOT
            local after = E.applyMove(s, moveOf(square(2, 3), square(2, 2), E.KING))
            local ending = E.checkEnd(after, 0, 1)
            expect(ending ~= nil).is(true)
            if ending then
                expect(ending.winner).is(E.PLAYER)
                expect(ending.reason).is('try')
            end
        end)
        test.case('capturing the king on the far row beats the try', function(expect)
            local s = empty()
            s.board[square(0, 4) + 1] = E.KING
            s.board[square(1, 4) + 1] = -E.ROOK
            s.board[square(2, 1) + 1] = -E.KING
            s.turn = E.BOT
            local after = E.applyMove(s, moveOf(square(1, 4), square(0, 4), E.ROOK))
            local ending = E.checkEnd(after, E.KING, 1)
            expect(ending ~= nil).is(true)
            if ending then
                expect(ending.winner).is(E.BOT)
                expect(ending.reason).is('capture')
            end
        end)
        test.case('a third repetition is a draw', function(expect)
            local s = empty()
            s.board[square(0, 1) + 1] = E.KING
            s.board[square(2, 4) + 1] = -E.KING
            local ending = E.checkEnd(s, 0, 3)
            expect(ending ~= nil).is(true)
            if ending then
                expect(ending.winner).is(0)
                expect(ending.reason).is('repetition')
            end
        end)
    end)

    test.group('bot', function()
        local function isLegal(state: E.State, move: E.Move): boolean
            for _, m in E.generateMoves(state) do
                if m.kind == move.kind and m.from == move.from and m.to == move.to and m.piece == move.piece then
                    return true
                end
            end
            return false
        end

        local function hanging(): E.State
            local s = empty()
            s.turn = E.BOT
            s.board[square(1, 4) + 1] = -E.KING
            s.board[square(1, 1) + 1] = E.KING
            s.board[square(0, 3) + 1] = E.ROOK
            return s
        end

        test.case('every level plays a legal opening reply', function(expect)
            local s = E.applyMove(E.newState(), moveOf(square(0, 1), square(0, 2), E.ROOK))
            for _, level in { 'easy', 'medium', 'hard' } do
                expect(isLegal(s, E.botChoose(s, level))).is(true)
            end
        end)
        test.case('easy never walks its king onto an attacked square', function(expect)
            for _ = 1, 50 do
                local s = hanging()
                local after = E.applyMove(s, E.botChoose(s, 'easy'))
                local king = E.findKing(after.board, E.BOT)
                expect(E.isAttacked(after.board, king, E.PLAYER)).is(false)
            end
        end)
        test.case('each level takes a king that is en prise', function(expect)
            for _, level in { 'easy', 'medium', 'hard' } do
                local s = empty()
                s.turn = E.BOT
                s.board[square(1, 3) + 1] = -E.ROOK
                s.board[square(2, 4) + 1] = -E.KING
                s.board[square(1, 2) + 1] = E.KING
                local m = E.botChoose(s, level)
                expect(m.to).is(square(1, 2))
            end
        end)
        test.case('medium sees a mate-in-one threat and avoids it', function(expect)
            -- The rook on A3 attacks A4 and the king on B4 can step there or stay.
            local s = hanging()
            local m = E.botChoose(s, 'medium')
            local after = E.applyMove(s, m)
            local king = E.findKing(after.board, E.BOT)
            expect(E.isAttacked(after.board, king, E.PLAYER)).is(false)
        end)
        test.case('bot-vs-bot games stay legal and terminate', function(expect)
            for _ = 1, 10 do
                local s = E.newState()
                local seen: { [string]: number } = {}
                local finished = false
                for _ = 1, 400 do
                    local moves = E.generateMoves(s)
                    expect(#moves > 0).is(true)
                    local move = moves[math.random(1, #moves)]
                    local captured = if move.kind == 'move' then s.board[move.to + 1] else 0
                    s = E.applyMove(s, move)
                    local key = E.positionKey(s)
                    seen[key] = (seen[key] or 0) + 1
                    if E.checkEnd(s, captured, seen[key]) ~= nil then
                        finished = true
                        break
                    end
                end
                expect(finished).is(true)
            end
        end)
    end)
end

return function(): Tests
    return setup
end

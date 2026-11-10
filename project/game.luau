-- The playfield: owns turn flow, input, piece motion and effects. Rules and the
-- bot live in engine.luau. Menus, buttons and text are markup in scene.rml; the
-- script talks to them only through the Game view model.
local E = require('engine')

-- Geometry matches the board and trays drawn in scene.rml.
local CELL_W = 107.5
local CELL_H = 95.5
local TILE_W = 101
local TILE_H = 88
local BOARD_X = 34
local BOARD_Y = 256
-- One tray slot per kind (rook, bishop, pawn); a second piece of the same kind
-- stacks on the first with a small offset.
local SLOT_GAP = 78
local SLOT_HIT = 26
local STACK_DX = 7
local STACK_DY = -5
local TRAY_Y_PLAYER = 705
local TRAY_Y_BOT = 147
local BOARD_SCALE = 0.95
local TRAY_SCALE = 0.55
local TAU = math.pi * 2

type Tween = {
    delay: number,
    t: number,
    dur: number,
    x0: number,
    y0: number,
    s0: number,
    x1: number,
    y1: number,
    s1: number,
    arc: number,
    bounce: boolean,
}

type Piece = {
    art: Artboard<Data.PieceVM>,
    vm: Data.PieceVM,
    kind: number,
    owner: number,
    square: number,
    slot: number,
    x: number,
    y: number,
    scale: number,
    tween: Tween?,
    shake: number,
    flip: number,
    flipTo: number,
}

type Particle = {
    x: number,
    y: number,
    vx: number,
    vy: number,
    gravity: number,
    life: number,
    maxLife: number,
    size: number,
    color: Color,
}

type Timer = { t: number, run: () -> () }

type Game = {
    pieceArt: Input<Artboard<Data.PieceVM>>,
    vm: ViewModel?,
    pieces: { Piece },
    state: E.State,
    seen: { [string]: number },
    timers: { Timer },
    particles: { Particle },
    circle: Path,
    square: Path,
    tile: Path,
    fill: Paint,
    ring: Paint,
    phase: string,
    level: string,
    twoPlayers: boolean,
    hints: boolean,
    onSplashDone: (() -> ())?,
    clock: number,
    selected: Piece?,
    selectedAt: number,
    targets: { [number]: boolean },
    dragging: boolean,
    dragMoved: boolean,
    dragOrigin: Vector,
    deselectOnUp: boolean,
    threatened: Piece?,
    tryRow: number,
    dim: number,
    thinkLeft: number,
    searchDepth: number,
    searchDone: boolean,
    botMove: E.Move?,
    ended: boolean,
    winner: number,
}

local KIND_NAME: { string } = { 'king', 'rook', 'bishop', 'pawn', 'gold' }

local function centerOf(square: number): Vector
    local col = square % 3
    local row = math.floor(square / 3)
    return Vector.xy(BOARD_X + col * CELL_W + CELL_W / 2, BOARD_Y + (3 - row) * CELL_H + CELL_H / 2)
end

local function slotCenter(owner: number, slot: number): Vector
    local y = if owner == E.PLAYER then TRAY_Y_PLAYER else TRAY_Y_BOT
    local kindSlot = math.floor(slot / 2)
    local stack = slot % 2
    -- The bot's tray is seen upside down, so its stack leans the other way.
    local dir = if owner == E.PLAYER then 1 else -1
    return Vector.xy(195 + (kindSlot - 1) * SLOT_GAP + stack * STACK_DX * dir, y + stack * STACK_DY * dir)
end

local function squareAt(p: Vector): number
    local col = math.floor((p.x - BOARD_X) / CELL_W)
    local row = 3 - math.floor((p.y - BOARD_Y) / CELL_H)
    if col < 0 or col > 2 or row < 0 or row > 3 then
        return -1
    end
    return row * 3 + col
end

local function setEnum(self: Game, name: string, value: string)
    local vm = self.vm
    if vm then
        local prop = vm:getEnum(name)
        if prop then
            prop.value = value
        end
    end
end

local function setText(self: Game, name: string, value: string)
    local vm = self.vm
    if vm then
        local prop = vm:getString(name)
        if prop then
            prop.value = value
        end
    end
end

local function setMessage(self: Game, value: string)
    setText(self, 'message', value)
end

local function setPhase(self: Game, phase: string)
    self.phase = phase
    setEnum(self, 'phase', phase)
end

local function paintFace(piece: Piece)
    local vm = piece.vm
    vm.showKing.value = if piece.kind == E.KING then 1 else 0
    vm.showRook.value = if piece.kind == E.ROOK then 1 else 0
    vm.showBishop.value = if piece.kind == E.BISHOP then 1 else 0
    vm.showPawn.value = if piece.kind == E.PAWN then 1 else 0
    vm.showGold.value = if piece.kind == E.GOLD then 1 else 0
    vm.pieceType.value = KIND_NAME[piece.kind] :: any
    vm.owner.value = (if piece.owner == E.PLAYER then 'player' else 'bot') :: any
    vm.rimColor.value = if piece.owner == E.PLAYER then Color.rgb(46, 125, 107) else Color.rgb(176, 58, 46)
    vm.sideBlue.value = if piece.owner == E.PLAYER then 1 else 0
    vm.sideRed.value = if piece.owner == E.PLAYER then 0 else 1
end

-- The move-direction dots on every piece follow one switch on the play screen.
local function applyHints(self: Game)
    local on = if self.hints then 1 else 0
    for _, piece in self.pieces do
        piece.vm.showHints.value = on
    end
    local vm = self.vm
    if vm then
        local prop = vm:getNumber('hintsOn')
        if prop then
            prop.value = on
        end
    end
end

local function after(self: Game, seconds: number, run: () -> ())
    table.insert(self.timers, { t = seconds, run = run })
end

local function tweenTo(p: Piece, delay: number, dur: number, to: Vector, scale: number, arc: number, bounce: boolean)
    p.tween = {
        delay = delay,
        t = 0,
        dur = dur,
        x0 = p.x,
        y0 = p.y,
        s0 = p.scale,
        x1 = to.x,
        y1 = to.y,
        s1 = scale,
        arc = arc,
        bounce = bounce,
    }
end

local function burst(self: Game, at: Vector, count: number, speed: number, color: Color, gravity: number)
    for _ = 1, count do
        local angle = math.random() * TAU
        local v = speed * (0.4 + math.random() * 0.6)
        local life = 0.35 + math.random() * 0.35
        table.insert(self.particles, {
            x = at.x,
            y = at.y,
            vx = math.cos(angle) * v,
            vy = math.sin(angle) * v,
            gravity = gravity,
            life = life,
            maxLife = life,
            size = 3 + math.random() * 4,
            color = color,
        })
    end
end

local function confetti(self: Game)
    local colors = { Color.rgb(230, 92, 70), Color.rgb(70, 160, 130), Color.rgb(240, 190, 70), Color.rgb(90, 130, 220) }
    for _ = 1, 110 do
        local life = 1.6 + math.random() * 1.2
        table.insert(self.particles, {
            x = math.random() * 390,
            y = -20 - math.random() * 240,
            vx = -40 + math.random() * 80,
            vy = 90 + math.random() * 120,
            gravity = 120,
            life = life,
            maxLife = life,
            size = 4 + math.random() * 5,
            color = colors[math.random(1, #colors)],
        })
    end
end

local function clearSelection(self: Game)
    self.selected = nil
    self.targets = {}
    self.dragging = false
    self.dragMoved = false
    self.deselectOnUp = false
    local vm = self.vm
    if vm then
        local prop = vm:getNumber('selectedSquare')
        if prop then
            prop.value = -1
        end
    end
end

local function select(self: Game, piece: Piece)
    self.selected = piece
    self.selectedAt = self.clock
    self.targets = {}
    for _, move in E.generateMoves(self.state) do
        local mine = false
        if piece.square >= 0 then
            mine = move.kind == 'move' and move.from == piece.square
        else
            mine = move.kind == 'drop' and move.piece == piece.kind
        end
        if mine then
            self.targets[move.to] = true
        end
    end
    local vm = self.vm
    if vm then
        local prop = vm:getNumber('selectedSquare')
        if prop then
            prop.value = piece.square
        end
    end
    if piece.square < 0 then
        setMessage(self, 'Chọn ô để thả')
    end
end

local function pieceOn(self: Game, square: number): Piece?
    for _, piece in self.pieces do
        if piece.square == square then
            return piece
        end
    end
    return nil
end

local function freeSlot(self: Game, owner: number, kind: number): number
    local base = (kind - E.ROOK) * 2
    for offset = 0, 1 do
        local taken = false
        for _, piece in self.pieces do
            if piece.owner == owner and piece.square < 0 and piece.slot == base + offset then
                taken = true
            end
        end
        if not taken then
            return base + offset
        end
    end
    return base
end

local function refreshDanger(self: Game)
    self.threatened = nil
    self.tryRow = -1
    local board = self.state.board
    local tryPending = false
    for _, side in { E.PLAYER, E.BOT } do
        local king = E.findKing(board, side)
        if king >= 0 then
            if E.isAttacked(board, king, -side) then
                local watched = if self.twoPlayers then side == self.state.turn else side == E.PLAYER
                if watched then
                    self.threatened = pieceOn(self, king)
                end
            end
            if E.rowOf(king) == E.farRow(side) then
                tryPending = true
                self.tryRow = E.rowOf(king)
            end
        end
    end
    local vm = self.vm
    if vm then
        local prop = vm:getBoolean('kingTryPending')
        if prop then
            prop.value = tryPending
        end
    end
end

local function beginBotTurn(self: Game)
    setPhase(self, 'botTurn')
    setEnum(self, 'turn', 'bot')
    setMessage(self, 'Máy đang nghĩ…')
    self.thinkLeft = 0.6 + math.random() * 0.6
    self.searchDepth = 1
    self.searchDone = self.level == 'easy'
    if self.level == 'easy' then
        self.botMove = E.easyMove(self.state)
    else
        self.botMove = nil
    end
end

-- Whoever is to move: the bottom player, or either player in two-player mode.
local function beginPlayerTurn(self: Game)
    setPhase(self, 'playerTurn')
    local side = self.state.turn
    setEnum(self, 'turn', if side == E.PLAYER then 'player' else 'bot')
    local prefix = ''
    if self.twoPlayers then
        prefix = if side == E.PLAYER then 'Người 1: ' else 'Người 2: '
    end
    if self.threatened then
        setMessage(self, prefix .. 'Hổ đang bị đe doạ')
    elseif self.twoPlayers then
        setMessage(self, prefix .. 'đến lượt')
    else
        setMessage(self, 'Đến lượt bạn')
    end
end

local function finish(self: Game, ending: E.Ending)
    self.ended = true
    self.winner = ending.winner
    self.threatened = nil
    local reasons: { [string]: string } = {
        capture = 'Bắt được Hổ',
        try = 'Hổ về đích',
        repetition = 'Thế cờ lặp lại 3 lần',
    }
    local result = 'draw'
    local title = 'Hòa'
    if ending.winner == E.PLAYER then
        result = 'playerWin'
        title = if self.twoPlayers then 'Người 1 thắng!' else 'Bạn thắng!'
        confetti(self)
    elseif ending.winner == E.BOT then
        result = 'botWin'
        title = if self.twoPlayers then 'Người 2 thắng!' else 'Bạn thua'
        if self.twoPlayers then
            confetti(self)
        end
    end
    setEnum(self, 'result', result)
    setEnum(self, 'winReason', ending.reason)
    setText(self, 'resultTitle', title)
    setText(self, 'resultReason', reasons[ending.reason])
    setMessage(self, '')
    setPhase(self, 'animating')
    -- Leave the board visible for a moment before the result panel slides in.
    after(self, 1.3, function()
        setPhase(self, 'gameEnd')
        local vm = self.vm
        if vm then
            local trigger = vm:getTrigger('onGameEnd')
            if trigger then
                trigger:fire()
            end
        end
    end)
end

-- Splash moments are drawn by splash.luau; these numbers pick the artboard.
local SPLASH_PROMOTE = 1
local SPLASH_BY_CAPTURER: { [number]: number } = {
    [E.PAWN] = 2,
    [E.GOLD] = 3,
    [E.BISHOP] = 4,
    [E.ROOK] = 5,
}

-- Asks splash.luau for a moment and runs `continue` once it reports back.
local function playSplash(self: Game, kind: number, side: number, continue: () -> ())
    local vm = self.vm
    local trigger = if vm then vm:getTrigger('playSplash') else nil
    if vm == nil or trigger == nil then
        continue()
        return
    end
    local kindProp = vm:getNumber('splashKind')
    if kindProp then
        kindProp.value = kind
    end
    local sideProp = vm:getNumber('splashSide')
    if sideProp then
        sideProp.value = if side == E.PLAYER then 0 else 1
    end
    self.onSplashDone = continue
    trigger:fire()
end

local function commit(self: Game, move: E.Move)
    local state = self.state
    local side = state.turn
    local captured = if move.kind == 'move' then state.board[move.to + 1] else 0
    local mover: Piece? = nil
    if move.kind == 'move' then
        mover = pieceOn(self, move.from)
    else
        local top = -1
        for _, piece in self.pieces do
            if piece.owner == side and piece.square < 0 and piece.kind == move.piece and piece.slot > top then
                top = piece.slot
                mover = piece
            end
        end
    end
    clearSelection(self)
    setPhase(self, 'animating')

    local victim = pieceOn(self, move.to)
    if victim and victim ~= mover then
        victim.shake = 0.18
        victim.square = -1
        victim.owner = side
        if victim.kind == E.GOLD then
            victim.kind = E.PAWN
        end
        -- A king has no tray slot; the game is over and it simply flies off.
        if victim.kind ~= E.KING then
            victim.slot = freeSlot(self, side, victim.kind)
            tweenTo(victim, 0.2, 0.42, slotCenter(side, victim.slot), TRAY_SCALE, 60, true)
        else
            victim.slot = 0
            tweenTo(victim, 0.2, 0.42, slotCenter(side, 2), TRAY_SCALE, 60, false)
        end
        paintFace(victim)
    end

    self.state = E.applyMove(state, move)
    local promoted = false
    if mover then
        mover.square = move.to
        mover.slot = -1
        local target = centerOf(move.to)
        if move.kind == 'drop' then
            tweenTo(mover, 0, 0.32, target, BOARD_SCALE, 40, true)
            after(self, 0.3, function()
                burst(self, target, 12, 90, Color.rgb(170, 140, 100), 200)
            end)
        else
            tweenTo(mover, 0, 0.26, target, BOARD_SCALE, 16, true)
            local cell = self.state.board[move.to + 1]
            if math.abs(cell) == E.GOLD and mover.kind == E.PAWN then
                promoted = true
                mover.flipTo = E.GOLD
                local flipping: Piece = mover
                after(self, 0.3, function()
                    flipping.flip = 0.4
                    burst(self, target, 22, 170, Color.rgb(250, 215, 110), 60)
                end)
            end
        end
    end

    local key = E.positionKey(self.state)
    self.seen[key] = (self.seen[key] or 0) + 1
    local repeats = self.seen[key]
    local ending = E.checkEnd(self.state, captured, repeats)

    local wait = 0.4
    if captured ~= 0 then
        wait = 0.72
    elseif promoted then
        wait = 0.75
    end
    local function continue()
        refreshDanger(self)
        if ending then
            finish(self, ending)
        elseif self.state.turn == E.BOT and not self.twoPlayers then
            beginBotTurn(self)
        else
            beginPlayerTurn(self)
        end
    end

    -- Catching the king outranks a promotion made on the same move.
    local splash = 0
    if mover and math.abs(captured) == E.KING then
        splash = SPLASH_BY_CAPTURER[mover.kind] or 0
    elseif promoted then
        splash = SPLASH_PROMOTE
    end
    if splash ~= 0 then
        after(self, if splash == SPLASH_PROMOTE then 0.75 else 0.55, function()
            playSplash(self, splash, side, continue)
        end)
    else
        after(self, wait, continue)
    end
end

local function setup(self: Game)
    self.onSplashDone = nil
    self.state = E.newState()
    self.seen = { [E.positionKey(self.state)] = 1 }
    self.timers = {}
    self.particles = {}
    self.ended = false
    self.winner = 0
    self.dim = 0
    self.threatened = nil
    self.tryRow = -1
    clearSelection(self)
    setEnum(self, 'result', 'none')
    setEnum(self, 'winReason', 'none')
    setPhase(self, 'setup')
    setMessage(self, '')
    local next = 1
    local delay = 0
    for square = 0, 11 do
        local cell = self.state.board[square + 1]
        if cell ~= 0 then
            local piece = self.pieces[next]
            next += 1
            piece.kind = math.abs(cell)
            piece.owner = if cell > 0 then E.PLAYER else E.BOT
            piece.square = square
            piece.slot = -1
            piece.shake = 0
            piece.flip = 0
            piece.flipTo = 0
            local target = centerOf(square)
            piece.x = target.x
            piece.y = target.y - 620
            piece.scale = BOARD_SCALE
            tweenTo(piece, delay, 0.42, target, BOARD_SCALE, 0, true)
            delay += 0.06
            paintFace(piece)
        end
    end
    applyHints(self)
    after(self, delay + 0.5, function()
        beginPlayerTurn(self)
    end)
end

local function setPickLevel(self: Game, value: boolean)
    local vm = self.vm
    if vm then
        local prop = vm:getBoolean('pickLevel')
        if prop then
            prop.value = value
        end
    end
end

local function startGame(self: Game)
    setPickLevel(self, false)
    local vm = self.vm
    local level = 'easy'
    if vm then
        local prop = vm:getEnum('difficulty')
        if prop then
            level = prop.value
        end
    end
    self.level = level
    self.twoPlayers = false
    if vm then
        local mode = vm:getEnum('mode')
        if mode then
            self.twoPlayers = mode.value == 'twoPlayers'
        end
    end
    setText(self, 'topName', if self.twoPlayers then 'Người 2' else 'Máy')
    setup(self)
end

local function toMenu(self: Game)
    self.timers = {}
    self.particles = {}
    self.onSplashDone = nil
    clearSelection(self)
    setPickLevel(self, false)
    setPhase(self, 'menu')
end

local function rulesOpen(self: Game): boolean
    local vm = self.vm
    if vm then
        local prop = vm:getBoolean('showRules')
        if prop then
            return prop.value
        end
    end
    return false
end

-- init runs twice and the view model is absent the first time, so this only
-- connects once one is there.
local function connect(self: Game, context: Context)
    if self.vm ~= nil then
        return
    end
    local vm = context:viewModel()
    if vm == nil then
        return
    end
    self.vm = vm
    local start = vm:getTrigger('start')
    if start then
        start:addListener(function()
            startGame(self)
        end)
    end
    local restart = vm:getTrigger('restart')
    if restart then
        restart:addListener(function()
            if not rulesOpen(self) then
                startGame(self)
            end
        end)
    end
    local splashDone = vm:getTrigger('splashDone')
    if splashDone then
        splashDone:addListener(function()
            local continue = self.onSplashDone
            self.onSplashDone = nil
            if continue then
                continue()
            end
        end)
    end
    local toggleHints = vm:getTrigger('toggleHints')
    if toggleHints then
        toggleHints:addListener(function()
            if self.phase ~= 'menu' and not rulesOpen(self) then
                self.hints = not self.hints
                applyHints(self)
            end
        end)
    end
    local goMenu = vm:getTrigger('goMenu')
    if goMenu then
        goMenu:addListener(function()
            if self.phase ~= 'menu' and not rulesOpen(self) then
                toMenu(self)
            end
        end)
    end
end

function init(self: Game, context: Context): boolean
    connect(self, context)
    if #self.pieces > 0 then
        return true
    end
    for _ = 1, 8 do
        local data = Data.PieceVM.new()
        local art = self.pieceArt:instance(data)
        art.frameOrigin = false
        table.insert(self.pieces, {
            art = art,
            vm = data,
            kind = E.PAWN,
            owner = E.PLAYER,
            square = -2,
            slot = -1,
            x = -500,
            y = -500,
            scale = 0,
            tween = nil,
            shake = 0,
            flip = 0,
            flipTo = 0,
        })
    end
    return true
end

local function stepBot(self: Game, seconds: number)
    if not self.searchDone then
        local limit = if self.level == 'medium' then E.DEPTH_MEDIUM else E.DEPTH_HARD
        -- One deeper iteration per frame, so no single frame carries the search.
        local found = E.searchRoot(self.state, self.searchDepth, 8000)
        if found then
            self.botMove = found
        end
        if found == nil or self.searchDepth >= limit then
            self.searchDone = true
        end
        self.searchDepth += 1
    end
    self.thinkLeft -= seconds
    if self.thinkLeft <= 0 and self.searchDone then
        commit(self, self.botMove or E.easyMove(self.state))
    end
end

local function easeOutBack(t: number): number
    local c = 1.4
    local u = t - 1
    return 1 + (c + 1) * u * u * u + c * u * u
end

local function easeInOut(t: number): number
    return t * t * (3 - 2 * t)
end

local function advanceTween(piece: Piece, seconds: number)
    local tw = piece.tween
    if tw == nil then
        return
    end
    if tw.delay > 0 then
        tw.delay -= seconds
        return
    end
    tw.t = math.min(tw.t + seconds, tw.dur)
    local u = tw.t / tw.dur
    local e = if tw.bounce then easeOutBack(u) else easeInOut(u)
    piece.x = tw.x0 + (tw.x1 - tw.x0) * e
    piece.y = tw.y0 + (tw.y1 - tw.y0) * e - math.sin(u * math.pi) * tw.arc
    piece.scale = tw.s0 + (tw.s1 - tw.s0) * easeInOut(u)
    if tw.t >= tw.dur then
        piece.x = tw.x1
        piece.y = tw.y1
        piece.scale = tw.s1
        piece.tween = nil
    end
end

function advance(self: Game, seconds: number): boolean
    self.clock += seconds

    -- Timers can schedule more timers, so they run from a snapshot.
    local due = self.timers
    self.timers = {}
    for _, timer in due do
        timer.t -= seconds
        if timer.t <= 0 then
            timer.run()
        else
            table.insert(self.timers, timer)
        end
    end

    if self.phase == 'botTurn' then
        stepBot(self, seconds)
    end

    for _, piece in self.pieces do
        advanceTween(piece, seconds)
        piece.shake = math.max(0, piece.shake - seconds)
        if piece.flip > 0 then
            local before = piece.flip
            piece.flip = math.max(0, piece.flip - seconds)
            if before > 0.2 and piece.flip <= 0.2 and piece.flipTo ~= 0 then
                piece.kind = piece.flipTo
                piece.flipTo = 0
                paintFace(piece)
            end
        end
        piece.art:advance(seconds)
    end

    local alive: { Particle } = {}
    for _, p in self.particles do
        p.life -= seconds
        if p.life > 0 then
            p.vy += p.gravity * seconds
            p.x += p.vx * seconds
            p.y += p.vy * seconds
            table.insert(alive, p)
        end
    end
    self.particles = alive

    local wanted = if self.ended and self.winner == E.BOT and not self.twoPlayers then 0.42 else 0
    self.dim += (wanted - self.dim) * math.min(1, seconds * 5)
    return true
end

local function fillCircle(self: Game, renderer: Renderer, x: number, y: number, radius: number, color: Color)
    self.fill.color = color
    renderer:save()
    renderer:transform(Mat2D.withScaleAndTranslation(radius, radius, x, y))
    renderer:drawPath(self.circle, self.fill)
    renderer:restore()
end

local function strokeCircle(self: Game, renderer: Renderer, x: number, y: number, radius: number, thickness: number, color: Color)
    self.ring.color = color
    self.ring.thickness = thickness / radius
    renderer:save()
    renderer:transform(Mat2D.withScaleAndTranslation(radius, radius, x, y))
    renderer:drawPath(self.circle, self.ring)
    renderer:restore()
end

local function fillRect(self: Game, renderer: Renderer, x: number, y: number, w: number, h: number, color: Color)
    self.fill.color = color
    renderer:save()
    renderer:transform(Mat2D.withScaleAndTranslation(w, h, x, y))
    renderer:drawPath(self.square, self.fill)
    renderer:restore()
end

local function fillTile(self: Game, renderer: Renderer, at: Vector, color: Color)
    self.fill.color = color
    renderer:save()
    renderer:transform(Mat2D.withTranslation(at.x, at.y - 1.5))
    renderer:drawPath(self.tile, self.fill)
    renderer:restore()
end

local function strokeTile(self: Game, renderer: Renderer, at: Vector, thickness: number, color: Color)
    self.ring.color = color
    self.ring.thickness = thickness
    renderer:save()
    renderer:transform(Mat2D.withTranslation(at.x, at.y - 1.5))
    renderer:drawPath(self.tile, self.ring)
    renderer:restore()
end

local function drawHints(self: Game, renderer: Renderer)
    local selected = self.selected
    if selected == nil then
        return
    end
    if selected.square >= 0 then
        local c = centerOf(selected.square)
        fillTile(self, renderer, c, Color.rgba(255, 214, 110, 110))
        strokeTile(self, renderer, c, 4, Color.rgba(240, 170, 40, 230))
    end
    local origin = Vector.xy(selected.x, selected.y)
    for square, _ in self.targets do
        local c = centerOf(square)
        local distance = Vector.length(c - origin)
        local age = self.clock - self.selectedAt - distance * 0.0005
        local grow = math.clamp(age / 0.14, 0, 1)
        if grow > 0 then
            if self.state.board[square + 1] ~= 0 then
                fillTile(self, renderer, c, Color.rgba(230, 80, 60, math.floor(70 * grow)))
                strokeTile(self, renderer, c, 4, Color.rgba(214, 70, 52, math.floor(235 * grow)))
            else
                fillCircle(self, renderer, c.x, c.y, 15 * grow, Color.rgba(255, 248, 230, 230))
                fillCircle(self, renderer, c.x, c.y, 10 * grow, Color.rgba(46, 139, 122, 235))
            end
        end
    end
end

local function drawPiece(self: Game, renderer: Renderer, piece: Piece)
    if piece.scale <= 0 then
        return
    end
    local x = piece.x
    local y = piece.y
    local lift = 0
    local selected = self.selected == piece
    if selected then
        lift = 7
    end
    if self.phase == 'botTurn' and piece.owner == E.BOT and piece.square >= 0 then
        lift += (math.sin(self.clock * 4 + piece.square) + 1) * 1.2
    end
    if self.threatened == piece then
        x += math.sin(self.clock * 40) * 1.6
        local alpha = math.floor(150 + math.sin(self.clock * 7) * 95)
        strokeCircle(self, renderer, piece.x, piece.y, 45, 4, Color.rgba(220, 50, 40, alpha))
    end
    if piece.shake > 0 then
        x += math.sin(self.clock * 70) * 4
    end
    if self.ended and self.winner ~= 0 and piece.owner == self.winner and piece.square >= 0 then
        lift += math.abs(math.sin(self.clock * 6 + piece.square)) * 12
    end

    local shadow = 23.5 + lift * 0.6
    self.fill.feather = 14
    fillCircle(self, renderer, x, y + 8 + lift * 0.6, shadow * piece.scale * 1.5, Color.rgba(40, 20, 0, 90))
    self.fill.feather = 0
    if selected then
        strokeCircle(self, renderer, x, y - lift, 45 * piece.scale, 4, Color.rgba(255, 210, 90, 230))
    end

    local xScale = piece.scale
    if piece.flip > 0 then
        xScale *= math.max(0.04, math.abs(math.cos((0.4 - piece.flip) / 0.4 * math.pi)))
    end
    renderer:save()
    local m = Mat2D.withTranslation(x, y - lift)
    if piece.owner == E.BOT then
        m = m * Mat2D.withRotation(math.pi)
    end
    m = m * Mat2D.withScale(xScale, piece.scale)
    -- The Piece artboard draws around its own centre at (50, 50).
    m = m * Mat2D.withTranslation(-50, -50)
    renderer:transform(m)
    piece.art:draw(renderer)
    renderer:restore()
end

function draw(self: Game, renderer: Renderer)
    if self.phase == 'menu' then
        return
    end
    if self.tryRow >= 0 then
        local alpha = math.floor(70 + math.sin(self.clock * 5) * 40)
        for col = 0, 2 do
            fillTile(self, renderer, centerOf(self.tryRow * 3 + col), Color.rgba(255, 220, 110, alpha))
        end
    end
    drawHints(self, renderer)
    if self.dim > 0.01 then
        fillRect(self, renderer, 195, 446, 363, 425, Color.rgba(20, 10, 0, math.floor(self.dim * 255)))
    end
    -- Resting pieces first, with the bottom of each tray stack under its top.
    for pass = 0, 1 do
        for _, piece in self.pieces do
            local stacked = piece.square < 0 and piece.slot % 2 == 1
            if piece.tween == nil and self.selected ~= piece and (if stacked then 1 else 0) == pass then
                drawPiece(self, renderer, piece)
            end
        end
    end
    for _, piece in self.pieces do
        if piece.tween ~= nil or self.selected == piece then
            drawPiece(self, renderer, piece)
        end
    end
    if self.phase == 'botTurn' then
        for i = 0, 2 do
            local wave = math.sin(self.clock * 7 - i * 0.9)
            fillCircle(self, renderer, 258 + i * 13, 64 - math.max(0, wave) * 5, 4, Color.rgb(74, 47, 20))
        end
    end
    for _, p in self.particles do
        local alpha = math.floor(255 * math.min(1, p.life / p.maxLife * 2))
        fillCircle(self, renderer, p.x, p.y, p.size, Color.opacity(p.color, alpha / 255) :: Color)
    end
end

local function trayPieceAt(self: Game, p: Vector): Piece?
    for _, piece in self.pieces do
        if piece.owner == self.state.turn and piece.square < 0 and piece.kind ~= E.KING then
            if math.abs(p.x - piece.x) <= SLOT_HIT and math.abs(p.y - piece.y) <= SLOT_HIT + 6 then
                return piece
            end
        end
    end
    return nil
end

local function moveTo(self: Game, square: number): E.Move?
    local selected = self.selected
    if selected == nil or not self.targets[square] then
        return nil
    end
    if selected.square >= 0 then
        return { kind = 'move', from = selected.square, to = square, piece = selected.kind }
    end
    return { kind = 'drop', from = -1, to = square, piece = selected.kind }
end

local function canAct(self: Game): boolean
    return self.phase == 'playerTurn' and not rulesOpen(self)
end

function pointerDown(self: Game, event: PointerEvent)
    if not canAct(self) then
        return
    end
    local p = event.position
    local square = squareAt(p)
    local tray = trayPieceAt(self, p)
    if square < 0 and tray == nil then
        return
    end
    event:hit()

    if square >= 0 then
        local move = moveTo(self, square)
        if move then
            commit(self, move)
            return
        end
    end

    local piece: Piece? = tray
    if square >= 0 then
        local on = pieceOn(self, square)
        if on and on.owner == self.state.turn then
            piece = on
        else
            piece = nil
        end
    end

    if piece == nil then
        local selected = self.selected
        if selected then
            selected.shake = 0.25
        end
        return
    end
    self.deselectOnUp = self.selected == piece
    if self.selected ~= piece then
        select(self, piece)
    end
    self.dragging = true
    self.dragMoved = false
    self.dragOrigin = p
end

function pointerMove(self: Game, event: PointerEvent)
    local selected = self.selected
    if not self.dragging or selected == nil then
        return
    end
    event:hit()
    local p = event.position
    if not self.dragMoved and Vector.length(p - self.dragOrigin) < 8 then
        return
    end
    self.dragMoved = true
    selected.x = p.x
    selected.y = p.y
    selected.scale = BOARD_SCALE
end

local function restPiece(piece: Piece)
    if piece.square >= 0 then
        tweenTo(piece, 0, 0.16, centerOf(piece.square), BOARD_SCALE, 0, false)
    else
        tweenTo(piece, 0, 0.16, slotCenter(piece.owner, piece.slot), TRAY_SCALE, 0, false)
    end
end

function pointerUp(self: Game, event: PointerEvent)
    local selected = self.selected
    if not self.dragging or selected == nil then
        self.dragging = false
        return
    end
    event:hit()
    self.dragging = false
    if self.dragMoved then
        local square = squareAt(event.position)
        local move: E.Move? = nil
        if square >= 0 then
            move = moveTo(self, square)
        end
        if move then
            commit(self, move)
        else
            restPiece(selected)
            selected.shake = 0.25
        end
    elseif self.deselectOnUp then
        clearSelection(self)
        beginPlayerTurn(self)
    end
end

local function unitCircle(): Path
    local k = 0.5522848
    local path = Path.new()
    path:moveTo(Vector.xy(1, 0))
    path:cubicTo(Vector.xy(1, k), Vector.xy(k, 1), Vector.xy(0, 1))
    path:cubicTo(Vector.xy(-k, 1), Vector.xy(-1, k), Vector.xy(-1, 0))
    path:cubicTo(Vector.xy(-1, -k), Vector.xy(-k, -1), Vector.xy(0, -1))
    path:cubicTo(Vector.xy(k, -1), Vector.xy(1, -k), Vector.xy(1, 0))
    path:close()
    return path
end

local function roundRect(w: number, h: number, r: number): Path
    local k = r * 0.5522848
    local x0, y0, x1, y1 = -w / 2, -h / 2, w / 2, h / 2
    local path = Path.new()
    path:moveTo(Vector.xy(x0 + r, y0))
    path:lineTo(Vector.xy(x1 - r, y0))
    path:cubicTo(Vector.xy(x1 - r + k, y0), Vector.xy(x1, y0 + r - k), Vector.xy(x1, y0 + r))
    path:lineTo(Vector.xy(x1, y1 - r))
    path:cubicTo(Vector.xy(x1, y1 - r + k), Vector.xy(x1 - r + k, y1), Vector.xy(x1 - r, y1))
    path:lineTo(Vector.xy(x0 + r, y1))
    path:cubicTo(Vector.xy(x0 + r - k, y1), Vector.xy(x0, y1 - r + k), Vector.xy(x0, y1 - r))
    path:lineTo(Vector.xy(x0, y0 + r))
    path:cubicTo(Vector.xy(x0, y0 + r - k), Vector.xy(x0 + r - k, y0), Vector.xy(x0 + r, y0))
    path:close()
    return path
end

local function unitSquare(): Path
    local path = Path.new()
    path:moveTo(Vector.xy(-0.5, -0.5))
    path:lineTo(Vector.xy(0.5, -0.5))
    path:lineTo(Vector.xy(0.5, 0.5))
    path:lineTo(Vector.xy(-0.5, 0.5))
    path:close()
    return path
end

return function(): Node<Game>
    return {
        pieceArt = late(),
        vm = nil,
        pieces = {},
        state = E.newState(),
        seen = {},
        timers = {},
        particles = {},
        circle = unitCircle(),
        square = unitSquare(),
        tile = roundRect(TILE_W, TILE_H, 12),
        fill = Paint.with({ style = 'fill', color = Color.rgb(255, 255, 255) }),
        ring = Paint.with({ style = 'stroke', thickness = 0.1, color = Color.rgb(255, 255, 255) }),
        phase = 'menu',
        level = 'easy',
        twoPlayers = false,
        hints = true,
        onSplashDone = nil,
        clock = 0,
        selected = nil,
        selectedAt = 0,
        targets = {},
        dragging = false,
        dragMoved = false,
        dragOrigin = Vector.xy(0, 0),
        deselectOnUp = false,
        threatened = nil,
        tryRow = -1,
        dim = 0,
        thinkLeft = 0,
        searchDepth = 1,
        searchDone = false,
        botMove = nil,
        ended = false,
        winner = 0,
        init = init,
        advance = advance,
        draw = draw,
        pointerDown = pointerDown,
        pointerMove = pointerMove,
        pointerUp = pointerUp,
    }
end

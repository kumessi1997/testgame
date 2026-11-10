-- Full-screen splash moments: a chick promoting, or an animal catching the king.
--
-- Each moment is its own artboard (Splash_Promote, Splash_Capture_Pawn, ...).
-- Redo the motion freely in the editor; the contract is only:
--   * the artboard is 390 x 844 and draws over the whole screen,
--   * its default state machine plays the moment once,
--   * a timeline named "Splash" sets how long the game waits for it.
-- The game asks for a moment through the Game view model (splashKind,
-- splashSide, playSplash) and hears back through splashDone.

local FALLBACK_SECONDS = 2.5
local SKIP_AFTER = 0.4

type Splash = {
    promote: Input<Artboard<Data.SplashVM>>,
    capturePawn: Input<Artboard<Data.SplashVM>>,
    captureGold: Input<Artboard<Data.SplashVM>>,
    captureBishop: Input<Artboard<Data.SplashVM>>,
    captureRook: Input<Artboard<Data.SplashVM>>,
    vm: ViewModel?,
    active: Artboard<Data.SplashVM>?,
    elapsed: number,
    length: number,
}

local function pick(self: Splash, kind: number): Input<Artboard<Data.SplashVM>>?
    if kind == 1 then
        return self.promote
    elseif kind == 2 then
        return self.capturePawn
    elseif kind == 3 then
        return self.captureGold
    elseif kind == 4 then
        return self.captureBishop
    elseif kind == 5 then
        return self.captureRook
    end
    return nil
end

local function readNumber(self: Splash, name: string): number
    local vm = self.vm
    if vm then
        local prop = vm:getNumber(name)
        if prop then
            return prop.value
        end
    end
    return 0
end

local function finish(self: Splash)
    if self.active == nil then
        return
    end
    self.active = nil
    local vm = self.vm
    if vm then
        local done = vm:getTrigger('splashDone')
        if done then
            done:fire()
        end
    end
end

local function play(self: Splash)
    local source = pick(self, readNumber(self, 'splashKind'))
    if source == nil then
        finish(self)
        return
    end
    local data = Data.SplashVM.new()
    data.side.value = readNumber(self, 'splashSide')
    local art = source:instance(data)
    art.frameOrigin = false
    local length = FALLBACK_SECONDS
    local timeline = art:animation('Splash')
    if timeline then
        length = timeline.duration
    end
    self.active = art
    self.elapsed = 0
    self.length = length
end

-- A new game or the menu drops whatever is showing, without reporting back.
local function cancel(self: Splash)
    self.active = nil
end

local function connect(self: Splash, context: Context)
    if self.vm ~= nil then
        return
    end
    local vm = context:viewModel()
    if vm == nil then
        return
    end
    self.vm = vm
    local trigger = vm:getTrigger('playSplash')
    if trigger then
        trigger:addListener(function()
            play(self)
        end)
    end
    for _, name in { 'start', 'restart', 'goMenu' } do
        local t = vm:getTrigger(name)
        if t then
            t:addListener(function()
                cancel(self)
            end)
        end
    end
end

function init(self: Splash, context: Context): boolean
    connect(self, context)
    return true
end

function advance(self: Splash, seconds: number): boolean
    local art = self.active
    if art then
        art:advance(seconds)
        self.elapsed += seconds
        if self.elapsed >= self.length then
            finish(self)
        end
    end
    return true
end

function draw(self: Splash, renderer: Renderer)
    local art = self.active
    if art then
        art:draw(renderer)
    end
end

-- While a splash is up it takes every tap; a tap after a moment skips it.
function pointerDown(self: Splash, event: PointerEvent)
    if self.active == nil then
        return
    end
    event:hit()
    if self.elapsed >= SKIP_AFTER then
        finish(self)
    end
end

return function(): Node<Splash>
    return {
        promote = late(),
        capturePawn = late(),
        captureGold = late(),
        captureBishop = late(),
        captureRook = late(),
        vm = nil,
        active = nil,
        elapsed = 0,
        length = FALLBACK_SECONDS,
        init = init,
        advance = advance,
        draw = draw,
        pointerDown = pointerDown,
    }
end

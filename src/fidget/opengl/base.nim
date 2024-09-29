import std/[os, times, unicode, strformat, importutils]
import ../common, ../input, ../internal
import chroma, pixie, opengl, perf, glfw, typography/textboxes, unicode, vmath, bumpy
from glfw/wrapper import getVideoMode, setWindowSize, setWindowSizeLimits

privateAccess(Monitor)

when defined(glDebugMessageCallback):
  import strformat, strutils

type
  MSAA* = enum
    msaaDisabled, msaa2x = 2, msaa4x = 4, msaa8x = 8

  MainLoopMode* = enum
    ## Only repaints on event
    ## Used for normal for desktop UI apps.
    RepaintOnEvent

    ## Repaints every frame (60hz or more based on display)
    ## Updates are done every matching frame time.
    ## Used for simple multimedia apps and games.
    RepaintOnFrame

    ## Repaints every frame (60hz or more based on display)
    ## But calls the tick function for keyboard and mouse updates at 240hz
    ## Used for low latency games.
    RepaintSplitUpdate

const
  deltaTick: int64 = 1_000_000_000 div 240

var
  window: glfw.Window
  loopMode*: MainLoopMode
  dpi*: float32
  drawFrame*: proc()
  running*, focused*, minimized*: bool
  programStartTime* = epochTime()
  fpsTimeSeries = newTimeSeries()
  tpsTimeSeries = newTimeSeries()
  prevFrameTime* = programStartTime
  frameTime* = prevFrameTime
  dt*, fps*, tps*, avgFrameTime*: float64
  frameCount*, tickCount*: int
  lastDraw, lastTick: int64

#[ var
  cursorDefault*: CursorHandle
  cursorPointer*: CursorHandle
  cursorGrab*: CursorHandle
  cursorNSResize*: CursorHandle ]#

#[ proc setCursor*(cursor: CursorHandle) =
  echo "set cursor"
  window.setCursor(cursor) ]#

proc updateWindowSize() =

  requestedFrame = true

  var (cwidth, cheight) = window.size()
  windowSize.x = float32(cwidth)
  windowSize.y = float32(cheight)

  (cwidth, cheight) = window.framebufferSize()
  windowFrame.x = float32(cwidth)
  windowFrame.y = float32(cheight)

  minimized = windowSize == vec2(0, 0)
  pixelRatio = if windowSize.x > 0: windowFrame.x / windowSize.x else: 0

  glViewport(0, 0, cwidth.cint, cheight.cint)

  let
    monitor = getPrimaryMonitor()
    mode = monitor.handle.getVideoMode()
  (cwidth, cheight) = monitor.physicalSizeMM()

  dpi = mode.width.float32 / (cwidth.float32 / 25.4)

  windowLogicalSize = windowSize / pixelScale * pixelRatio

proc setWindowTitle*(title: string) {.inline.} =
  window.title = title

proc preInput() =
  var (x, y) = window.cursorPos()
  mouse.pos = vec2(x, y)
  mouse.pos *= pixelRatio / mouse.pixelScale
  mouse.delta = mouse.pos - mouse.prevPos
  mouse.prevPos = mouse.pos

proc postInput() =
  clearInputs()

proc preTick() =
  discard

proc postTick() =
  tpsTimeSeries.addTime()
  tps = float64(tpsTimeSeries.num())

  inc tickCount
  lastTick += deltaTick

proc drawAndSwap() =
  ## Does drawing operations.
  inc frameCount
  fpsTimeSeries.addTime()
  fps = float64(fpsTimeSeries.num())
  avgFrameTime = fpsTimeSeries.avg()

  frameTime = epochTime()
  dt = frameTime - prevFrameTime
  prevFrameTime = frameTime

  assert drawFrame != nil
  drawFrame()

  var error: GLenum
  while (error = glGetError(); error != GL_NO_ERROR):
    echo "gl error: " & $error.uint32

  window.swapBuffers()

proc updateLoop*(poll = true) =
  if window.shouldClose():
    running = false
    return

  case loopMode:
    of RepaintOnEvent:
      if poll:
        pollEvents()
      if not requestedFrame or minimized:
        # Only repaint when necessary
        when not defined(emscripten):
          sleep(16)
        return
      requestedFrame = false
      preInput()
      if tickMain != nil:
        preTick()
        tickMain()
        postTick()
      drawAndSwap()
      postInput()

    of RepaintOnFrame:
      if poll:
        pollEvents()
      preInput()
      if tickMain != nil:
        preTick()
        tickMain()
        postTick()
      drawAndSwap()
      postInput()

    of RepaintSplitUpdate:
      if poll:
        pollEvents()
      preInput()
      while lastTick < getTicks():
        preTick()
        tickMain()
        postTick()
      drawAndSwap()
      postInput()

proc clearDepthBuffer*() =
  glClear(GL_DEPTH_BUFFER_BIT)

proc clearColorBuffer*(color: Color) =
  glClearColor(color.r, color.g, color.b, color.a)
  glClear(GL_COLOR_BUFFER_BIT)

proc useDepthBuffer*(on: bool) =
  if on:
    glDepthMask(GL_TRUE)
    glEnable(GL_DEPTH_TEST)
    glDepthFunc(GL_LEQUAL)
  else:
    glDepthMask(GL_FALSE)
    glDisable(GL_DEPTH_TEST)

proc exit*() =
  ## Cleanup GLFW.
  terminate()

proc glGetInteger*(what: GLenum): int =
  var val: GLint
  glGetIntegerv(what, val.addr)
  return val.int

proc onResize(handle: Window, res: tuple[w, h: int32]) =
  updateWindowSize()
  updateLoop(poll = false)

proc onFocus(window: Window, state: bool) =
  focused = state

proc onSetKey(
  window: Window, key: Key, scancode: int32, action: KeyAction, modifiers: set[ModifierKey]
) =
  requestedFrame = true
  let key = key.int32
  let setKey = action != kaUp

  keyboard.altKey = setKey and mkAlt in modifiers
  keyboard.ctrlKey = setKey and
    (mkCtrl in modifiers or mkSuper in modifiers)
  keyboard.shiftKey = setKey and mkShift in modifiers

  # Do the text box commands.
  if keyboard.focusNode != nil and setKey:
    keyboard.state = KeyState.Press
    let
      ctrl = keyboard.ctrlKey
      shift = keyboard.shiftKey
    case cast[Button](key):
      of ARROW_LEFT:
        if ctrl:
          textBox.leftWord(shift)
        else:
          textBox.left(shift)
      of ARROW_RIGHT:
        if ctrl:
          textBox.rightWord(shift)
        else:
          textBox.right(shift)
      of ARROW_UP:
        textBox.up(shift)
      of ARROW_DOWN:
        textBox.down(shift)
      of Button.HOME:
        textBox.startOfLine(shift)
      of Button.END:
        textBox.endOfLine(shift)
      of Button.PAGE_UP:
        textBox.pageUp(shift)
      of Button.PAGE_DOWN:
        textBox.pageDown(shift)
      of ENTER:
        #TODO: keyboard.multiline:
        textBox.typeCharacter(Rune(10))
      of BACKSPACE:
        textBox.backspace(shift)
      of DELETE:
        textBox.delete(shift)
      of LETTER_C: # copy
        if ctrl:
          base.window.clipboardString = textBox.copy()
      of LETTER_V: # paste
        if ctrl:
          textBox.paste($base.window.clipboardString())
      of LETTER_X: # cut
        if ctrl:
          base.window.clipboardString = textBox.cut()
      of LETTER_A: # select all
        if ctrl:
          textBox.selectAll()
      else:
        discard

  # Now do the buttons.
  if key < buttonDown.len and key >= 0:
    if buttonDown[key] == false and setKey:
      buttonToggle[key] = not buttonToggle[key]
      buttonPress[key] = true
    if buttonDown[key] == true and setKey == false:
      buttonRelease[key] = true
    buttonDown[key] = setKey

proc onScroll(window: Window, offset: tuple[x, y: float64]) =
  requestedFrame = true
  if keyboard.focusNode != nil:
    textBox.scrollBy(-offset.y * 50)
  else:
    mouse.wheelDelta += offset.y

proc onMouseButton(
  window: Window, button: MouseButton, pressed: bool, modifiers: set[ModifierKey]
) =
  requestedFrame = true
  let button = button.int32 + 1'i32
  let setKey = pressed != false

  if button < buttonDown.len.int32:
    if buttonDown[button] == false and setKey == true:
      buttonPress[button] = true
    buttonDown[button] = setKey

  if buttonDown[button] == false and setKey == false:
    buttonRelease[button] = true
  
proc onMouseMove(window: Window, pos: tuple[x, y: float64]) =
  requestedFrame = true

proc onSetCharCallback(window: Window, character: Rune) =
  requestedFrame = true
  if keyboard.focusNode != nil:
    keyboard.state = KeyState.Press
    textBox.typeCharacter(character)
  else:
    keyboard.state = KeyState.Press
    keyboard.keyString = character.toUTF8()

proc start*(openglVersion: (int, int), msaa: MSAA, mainLoopMode: MainLoopMode) =
  glfw.initialize()

  running = true
  loopMode = mainLoopMode

  #[ if msaa != msaaDisabled:
    windowHint(SAMPLES, msaa.cint)

  windowHint(OPENGL_FORWARD_COMPAT, GL_TRUE.cint)
  windowHint(OPENGL_PROFILE, OPENGL_CORE_PROFILE)
  windowHint(CONTEXT_VERSION_MAJOR, openglVersion[0].cint)
  windowHint(CONTEXT_VERSION_MINOR, openglVersion[1].cint) ]#

  if fullscreen:
    let
      monitor = getPrimaryMonitor()
      mode = getVideoMode(monitor.handle)

    window = newWindow()
    window.getHandle().setWindowSize(mode.width, mode.height)
  else:
    let
      monitor = getPrimaryMonitor()
    var (dpiScale, yScale) = monitor.contentScale()
    assert dpiScale == yScale

    window = newWindow()
    window.getHandle().setWindowSize(
      (windowSize.x / dpiScale * pixelScale).int32,
      (windowSize.y / dpiScale * pixelScale).int32
    )

  if window.isNil:
    quit(
      "Failed to open window. OpenGL version:" &
      &"{openglVersion[0]}.{$openglVersion[1]}"
    )

  window.makeContextCurrent()

  #cursorDefault = createStandardCursor(ARROW_CURSOR)
  #cursorPointer = createStandardCursor(HAND_CURSOR)
  #cursorGrab = createStandardCursor(HAND_CURSOR)
  #cursorNSResize = createStandardCursor(HRESIZE_CURSOR)

  when not defined(emscripten):
    swapInterval(1)
    # Load OpenGL
    loadExtensions()

  when defined(glDebugMessageCallback):
    let flags = glGetInteger(GL_CONTEXT_FLAGS)
    if (flags and GL_CONTEXT_FLAG_DEBUG_BIT.GLint) != 0:
      # Set up error logging
      proc printGlDebug(
        source, typ: GLenum,
        id: GLuint,
        severity: GLenum,
        length: GLsizei,
        message: ptr GLchar,
        userParam: pointer
      ) {.stdcall.} =
        echo &"source={toHex(source.uint32)} type={toHex(typ.uint32)} " &
          &"id={id} severity={toHex(severity.uint32)}: {$message}"
        if severity != GL_DEBUG_SEVERITY_NOTIFICATION:
          running = false

      glDebugMessageCallback(printGlDebug, nil)
      glEnable(GL_DEBUG_OUTPUT_SYNCHRONOUS)
      glEnable(GL_DEBUG_OUTPUT)

  when defined(printGLVersion):
    echo getVersionString()
    echo "GL_VERSION:", cast[cstring](glGetString(GL_VERSION))
    echo "GL_SHADING_LANGUAGE_VERSION:",
      cast[cstring](glGetString(GL_SHADING_LANGUAGE_VERSION))

  window.frameBufferSizeCb = onResize
  window.windowFocusCb = onFocus
  window.keyCb = onSetKey
  window.scrollCb = onScroll
  window.mouseButtonCb = onMouseButton
  window.cursorPositionCb = onMouseMove
  window.charCb = onSetCharCallback

  glEnable(GL_BLEND)
  #glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
  glBlendFuncSeparate(
    GL_SRC_ALPHA,
    GL_ONE_MINUS_SRC_ALPHA,
    GL_ONE,
    GL_ONE_MINUS_SRC_ALPHA
  )

  lastDraw = getTicks()
  lastTick = lastDraw

  onFocus(window, true)
  focused = true
  updateWindowSize()

proc captureMouse*() =
  window.cursorMode = cmDisabled

proc releaseMouse*() =
  window.cursorMode = cmNormal

proc hideMouse*() =
  window.cursorMode = cmHidden

proc setWindowBounds*(min, max: Vec2) =
  window.getHandle().setWindowSizeLimits(
    min.x.int32, min.y.int32, max.x.int32, max.y.int32
  )

proc takeScreenshot*(
  frame = rect(0, 0, windowFrame.x, windowFrame.y)
): pixie.Image =
  result = newImage(frame.w.int, frame.h.int)
  glReadPixels(
    frame.x.GLint,
    frame.y.GLint,
    frame.w.GLint,
    frame.h.GLint,
    GL_RGBA,
    GL_UNSIGNED_BYTE,
    result.data[0].addr
  )
  result.flipVertical()

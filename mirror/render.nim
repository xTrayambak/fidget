
import pixie, chroma, math, vmath, schema, print,
    typography, bumpy, strutils, tables

const
  white = rgba(255, 255, 255, 255)
  clear = rgba(0, 0, 0, 0)

var
  mainCtx*: Image
  # maskStack: seq[Image]
  nodeStack: seq[Node]
  parentNode: Node
  framePos*: Vec2
  imageCache: Table[string, Image]
  typefaceCache: Table[string, Typeface]

proc drawNode*(node: Node)

proc drawChildren(node: Node) =
  parentNode = node
  nodeStack.add(node)

  # Draw regular children:
  for child in node.children:
    drawNode(child)

  discard nodeStack.pop()
  if nodeStack.len > 0:
    parentNode = nodeStack[^1]

proc gradientPut(effectsCtx: Image, x, y: int, a: float32, fill: Paint) =
  var
    index = -1
  for i, stop in fill.gradientStops:
    if stop.position < a:
      index = i
    if stop.position > a:
      break
  var color: Color
  if index == -1:
    # first stop solid
    color = fill.gradientStops[0].color
  elif index + 1 >= fill.gradientStops.len:
    # last stop solid
    color = fill.gradientStops[index].color
  else:
    let
      gs1 = fill.gradientStops[index]
      gs2 = fill.gradientStops[index+1]
    color = mix(
      gs1.color,
      gs2.color,
      (a - gs1.position) / (gs2.position - gs1.position)
    )
  effectsCtx.setRgbaUnsafe(x, y, color.rgba)

proc applyPaint(maskCtx: Image, fill: Paint, node: Node, mat: Mat3) =

  if not fill.visible:
    return

  if maskCtx == nil:
    echo "maskCtx == nil:", node.name
    return

  #assert maskCtx != nil, "Mask is nil for id: " & node.id & "."

  let pos = vec2(mat[2, 0], mat[2, 1])

  proc toImageSpace(handle: Vec2): Vec2 =
    vec2(
      handle.x * node.absoluteBoundingBox.width + pos.x,
      handle.y * node.absoluteBoundingBox.height + pos.y,
    )

  proc toLineSpace(at, to, point: Vec2): float32 =
    let
      d = to - at
      det = d.x*d.x + d.y*d.y
    return (d.y*(point.y-at.y)+d.x*(point.x-at.x))/det

  var effectsCtx = newImage(maskCtx.width, maskCtx.height)

  if fill.`type` == "IMAGE":
    var image: Image
    if fill.imageRef notin imageCache:
      downloadImageRef(fill.imageRef)
      image = readImage("images/" & fill.imageRef & ".png")
      imageCache[fill.imageRef] = image
    else:
      image = imageCache[fill.imageRef]

    if fill.scaleMode == "FILL":
      let
        ratioW = image.width.float32 / node.size.x
        ratioH = image.height.float32 / node.size.y
        scale = min(ratioW, ratioH)
      let topRight = node.size / 2 - vec2(image.width/2, image.height/2) / scale
      effectsCtx = effectsCtx.draw(
        image,
        mat * translate(topRight) * scale(vec2(1/scale))
      )

    elif fill.scaleMode == "FIT":
      let
        ratioW = image.width.float32 / node.size.x
        ratioH = image.height.float32 / node.size.y
        scale = max(ratioW, ratioH)
      let topRight = node.size / 2 - vec2(image.width/2, image.height/2) / scale
      effectsCtx = effectsCtx.draw(
        image,
        mat * translate(topRight) * scale(vec2(1/scale))
      )

    elif fill.scaleMode == "STRETCH": # Figma ui calls this "crop".
      var mat: Mat3
      mat[0, 0] = fill.imageTransform[0][0]
      mat[0, 1] = fill.imageTransform[0][1]

      mat[1, 0] = fill.imageTransform[1][0]
      mat[1, 1] = fill.imageTransform[1][1]

      mat[2, 0] = fill.imageTransform[0][2]
      mat[2, 1] = fill.imageTransform[1][2]
      mat[2, 2] = 1

      mat = mat.inverse()
      mat[2, 0] = pos.x + mat[2, 0] * node.absoluteBoundingBox.width
      mat[2, 1] = pos.y + mat[2, 1] * node.absoluteBoundingBox.height
      let
        ratioW = image.width.float32 / node.absoluteBoundingBox.width
        ratioH = image.height.float32 / node.absoluteBoundingBox.height
        scale = min(ratioW, ratioH)
      mat = mat * scale(vec2(1/scale))
      effectsCtx = effectsCtx.draw(image, mat)

    elif fill.scaleMode == "TILE":
      image = image.resize(
        int(image.width.float32 * fill.scalingFactor),
        int(image.height.float32 * fill.scalingFactor))
      var x = 0.0
      while x < node.absoluteBoundingBox.width:
        var y = 0.0
        while y < node.absoluteBoundingBox.height:
          effectsCtx = effectsCtx.draw(image, vec2(x, y))
          y += image.height.float32
        x += image.width.float32

  elif fill.`type` == "GRADIENT_LINEAR":
    let
      at = fill.gradientHandlePositions[0].toImageSpace()
      to = fill.gradientHandlePositions[1].toImageSpace()
    for y in 0 ..< effectsCtx.height:
      for x in 0 ..< effectsCtx.width:
        let xy = vec2(x.float32, y.float32)
        let a = toLineSpace(at, to, xy)
        effectsCtx.gradientPut(x, y, a, fill)

  elif fill.`type` == "GRADIENT_RADIAL":
    let
      at = fill.gradientHandlePositions[0].toImageSpace()
      to = fill.gradientHandlePositions[1].toImageSpace()
      distance = dist(at, to)
    for y in 0 ..< effectsCtx.height:
      for x in 0 ..< effectsCtx.width:
        let xy = vec2(x.float32, y.float32)
        let a = (at - xy).length() / distance
        effectsCtx.gradientPut(x, y, a, fill)

  elif fill.`type` == "GRADIENT_ANGULAR":
    let
      at = fill.gradientHandlePositions[0].toImageSpace()
      to = fill.gradientHandlePositions[1].toImageSpace()
      gradientAngle = normalize(to - at).angle().fixAngle()
    for y in 0 ..< effectsCtx.height:
      for x in 0 ..< effectsCtx.width:
        let
          xy = vec2(x.float32, y.float32)
          angle = normalize(xy - at).angle()
          a = (angle + gradientAngle + PI/2).fixAngle() / 2 / PI + 0.5
        effectsCtx.gradientPut(x, y, a, fill)

  elif fill.`type` == "GRADIENT_DIAMOND":
    # TODO: implement GRADIENT_DIAMOND, now will just do GRADIENT_RADIAL
    let
      at = fill.gradientHandlePositions[0].toImageSpace()
      to = fill.gradientHandlePositions[1].toImageSpace()
      distance = dist(at, to)
    for y in 0 ..< effectsCtx.height:
      for x in 0 ..< effectsCtx.width:
        let xy = vec2(x.float32, y.float32)
        let a = (at - xy).length() / distance
        effectsCtx.gradientPut(x, y, a, fill)

  elif fill.`type` == "SOLID":
    var color = fill.color
    effectsCtx = effectsCtx.fill(color.rgba)
  else:
    echo "Not supported paint: ", fill.`type`

  ## Apply opacity
  if fill.opacity != 1.0:
    var opacity = newImageFill(
      effectsCtx.width,
      effectsCtx.height,
      color(0,0,0, fill.opacity).rgba
    )
    effectsCtx = effectsCtx.draw(opacity, blendMode = bmMask)

  effectsCtx = effectsCtx.draw(maskCtx, blendMode = bmMask)

  node.pixels = node.pixels.draw(effectsCtx, blendMode = parseBlendMode(fill.blendMode))

proc applyDropShadowEffect(effect: Effect, node: Node) =
  ## Draws the drop shadow.
  var shadow = node.pixels.shadow(
    effect.offset, effect.spread, effect.radius, effect.color)
  shadow = shadow.draw(node.pixels)
  node.pixels = shadow

proc applyLayerBlurEffect(effect: Effect, node: Node) =
  ## Blurs the layer.
  node.pixels = node.pixels.blur(effect.radius)

proc applyInnerShadowEffect(effect: Effect, node: Node, fillMaskCtx: Image) =
  ## Draws the inner shadow.
  var shadowCtx = fillMaskCtx.copy()
  # Invert colors of the fill mask.
  shadowCtx = shadowCtx.invert()
  # Blur the inverted fill.
  shadowCtx = shadowCtx.blur(effect.radius)
  # Color the inverted blurred fill.
  var colorCtx = newImageFill(
    shadowCtx.width, shadowCtx.height, effect.color.rgba)
  colorCtx = colorCtx.draw(shadowCtx, blendMode = bmMask)
  # Only have the shadow be on the fill.
  colorCtx = colorCtx.draw(fillMaskCtx, blendMode = bmMask)
  # Draw it back.
  node.pixels = node.pixels.draw(colorCtx)

proc roundRect(path: Path, x, y, w, h, nw, ne, se, sw: float32) =
  ## Draw a round rectangle with different radius corners.
  let
    maxRaidus = min(w/2, h/2)
    nw = min(nw, maxRaidus)
    ne = min(ne, maxRaidus)
    se = min(se, maxRaidus)
    sw = min(sw, maxRaidus)
  path.moveTo(x+nw, y)
  path.arcTo(x+w, y,   x+w, y+h, ne)
  path.arcTo(x+w, y+h, x,   y+h, se)
  path.arcTo(x,   y+h, x,   y,   sw)
  path.arcTo(x,   y,   x+w, y,   nw)
  path.closePath()

proc roundRectRev(path: Path, x, y, w, h, nw, ne, se, sw: float32) =
  ## Same as roundRect but in reverse order so that you can cut out a hole.
  let
    maxRaidus = min(w/2, h/2)
    nw = min(nw, maxRaidus)
    ne = min(ne, maxRaidus)
    se = min(se, maxRaidus)
    sw = min(sw, maxRaidus)
  path.moveTo(x+w+ne, y)
  path.arcTo(x,   y,   x,   y+h,   nw)
  path.arcTo(x,   y+h, x+w, y+h,   sw)
  path.arcTo(x+w, y+h, x+w, y, se)
  path.arcTo(x+w, y,   x,   y, ne)
  path.closePath()

proc markDirty*(node: Node, value = true) =
  ## Marks the entire tree dirty or not dirty.
  node.dirty = value
  for c in node.children:
    markDirty(c, value)

proc checkDirty(node: Node) =
  ## Makes sure if children are dirty, parents are dirty too!
  for c in node.children:
    checkDirty(c)
    if c.dirty == true:
      node.dirty = true

proc transform(node: Node): Mat3 =
  ## Returns Mat3 transform of the node.
  result[0, 0] = node.relativeTransform[0][0]
  result[0, 1] = node.relativeTransform[1][0]
  result[0, 2] = 0

  result[1, 0] = node.relativeTransform[0][1]
  result[1, 1] = node.relativeTransform[1][1]
  result[1, 2] = 0

  result[2, 0] = node.relativeTransform[0][2]
  result[2, 1] = node.relativeTransform[1][2]
  result[2, 2] = 1

const pixelBounds = true

proc computePixelBox*(node: Node) =

  when not pixelBounds:
    node.pixelBox.xy = vec2(0, 0)
    node.pixelBox.wh = vec2(mainCtx.width.float32, mainCtx.height.float32)
    return

  ## Computes pixel bounds.
  ## Takes into account width, height and shadow extent, and children.
  node.pixelBox.xy = node.absoluteBoundingBox.xy + framePos
  node.pixelBox.wh = node.absoluteBoundingBox.wh

  var s = 0.0

  # Takes stroke into account:
  if node.strokes.len > 0:
    s = max(s, node.strokeWeight)

  # Take drop shadow into account:
  for effect in node.effects:
    if effect.`type` in ["DROP_SHADOW", "INNER_SHADOW", "LAYER_BLUR"]:
      # Note: INNER_SHADOW needs just as much area around as drop shadow
      # because it needs to blur in.
      s = max(
        s,
        effect.radius +
        effect.spread +
        abs(effect.offset.x) +
        abs(effect.offset.y)
      )

  node.pixelBox.xy = node.pixelBox.xy - vec2(s, s)
  node.pixelBox.wh = node.pixelBox.wh + vec2(s, s) * 2

  # Take children into account:
  for child in node.children:
    child.computePixelBox()

    if not node.clipsContent:
      # TODO: clips content should still respect shadows.
      node.pixelBox = node.pixelBox or child.pixelBox

  node.pixelBox.x = node.pixelBox.x.floor
  node.pixelBox.y = node.pixelBox.y.floor
  node.pixelBox.w = node.pixelBox.w.ceil
  node.pixelBox.h = node.pixelBox.h.ceil

proc drawCompleteFrame*(node: Node): Image =
  ## Draws full frame that is ready to be displayed.

  framePos = -node.absoluteBoundingBox.xy

  checkDirty(node)

  if node.pixels != nil and not node.dirty:
    return node.pixels

  mainCtx = newImage(
    node.absoluteBoundingBox.width.int,
    node.absoluteBoundingBox.height.int
  )

  drawNode(node)

  assert mainCtx != nil
  assert node.pixels != nil

  proc putNode(node: Node) =
    if node.pixels != nil:
      #mainCtx.writeFile("tmp/pre." & node.name & ".png")
      #echo parseBlendMode(node.blendMode)
      mainCtx = mainCtx.draw(
        node.pixels,
        node.pixelBox.xy,
        parseBlendMode(node.blendMode)
      )
      #mainCtx.writeFile("tmp/post." & node.name & "." & $parseBlendMode(node.blendMode) & ".png")
    if node.`type` != "BOOLEAN_OPERATION":
      for c in node.children:
        putNode(c)
  putNode(node)

  #mainCtx.draw(node.pixels, blendMode = parseBlendMode(node.blendMode))

  return mainCtx

proc drawNode*(node: Node) =
  ## Draws a node.
  ## Note: Must be called inside drawCompleteFrame.

  if not node.visible or node.opacity == 0:
    return

  if node.pixels != nil and node.dirty == false:
    # Nothing to do, node.pixels contains the cached version.
    return

  node.computePixelBox()

  # Make sure node.pixels is there and is the right size:
  let
    w = ceil(node.pixelBox.w).int
    h = ceil(node.pixelBox.h).int

  node.pixels = newImage(w, h)

  var
    fillMaskCtx: Image
    strokeMaskCtx: Image

  var mat = mat3()
  for i, node in nodeStack:
    var transform = node.transform()
    if i == 0:
      # root node
      transform = mat3()
    mat = mat * transform

  if nodeStack.len != 0:
    mat = mat * node.transform()

  mat[2, 0] = mat[2, 0] - node.pixelBox.x
  mat[2, 1] = mat[2, 1] - node.pixelBox.y

  # var s = ""
  # for node in nodeStack:
  #   s.add(" ")
  # echo s, node.name, "|", node.pixelBox, "...", repr(node.transform()).strip()

  case node.`type`
  of "DOCUMENT", "CANVAS":
    quit(node.`type` & " can't be drawn.")

  of "RECTANGLE", "FRAME", "GROUP", "COMPONENT", "INSTANCE":
    if node.fills.len > 0:
      #echo "making rect", node.size
      fillMaskCtx = newImage(w, h)
      var path = newPath()
      if node.cornerRadius > 0:
        # Rectangle with common corners.
        path.roundRect(
          x = 0,
          y = 0,
          w = node.size.x,
          h = node.size.y,
          nw = node.cornerRadius,
          ne = node.cornerRadius,
          se = node.cornerRadius,
          sw = node.cornerRadius
        )
      elif node.rectangleCornerRadii.len == 4:
        # Rectangle with different corners.
        path.roundRect(
          x = 0,
          y = 0,
          w = node.size.x,
          h = node.size.y,
          nw = node.rectangleCornerRadii[0],
          ne = node.rectangleCornerRadii[1],
          se = node.rectangleCornerRadii[2],
          sw = node.rectangleCornerRadii[3],
        )
      else:
        # Basic rectangle.
        path.rect(
          x = 0,
          y = 0,
          w = node.size.x,
          h = node.size.y,
        )
      fillMaskCtx = fillMaskCtx.fillPath(
        path,
        white,
        mat,
      )

    if node.strokes.len > 0:
      strokeMaskCtx = newImage(w, h)
      let
        x = 0.0
        y = 0.0
        w = node.size.x
        h = node.size.y
      var
        inner = 0.0
        outer = 0.0
        path: Path
      if node.strokeAlign == "INSIDE":
        inner = node.strokeWeight
      elif node.strokeAlign == "OUTSIDE":
        outer = node.strokeWeight
      elif node.strokeAlign == "CENTER":
        inner = node.strokeWeight / 2
        outer = node.strokeWeight / 2
      else:
        quit("invalid strokeWeight")

      if node.cornerRadius > 0:
        # Rectangle with common corners.
        let
          r = node.cornerRadius
        path = newPath()
        path.roundRect(x-outer,y-outer,w+outer*2,h+outer*2,r+outer,r+outer,r+outer,r+outer)
        path.roundRectRev(x+inner,y+inner,w-inner*2,h-inner*2,r-inner,r-inner,r-inner,r-inner)

      elif node.rectangleCornerRadii.len == 4:
        # Rectangle with different corners.
        path = newPath()
        let
          nw = node.rectangleCornerRadii[0]
          ne = node.rectangleCornerRadii[1]
          se = node.rectangleCornerRadii[2]
          sw = node.rectangleCornerRadii[3]
        path.roundRect(x-outer,y-outer,w+outer*2,h+outer*2,nw+outer,ne+outer,se+outer,sw+outer)
        path.roundRectRev(x+inner,y+inner,w-inner*2,h-inner*2,nw-inner,ne-inner,se-inner,sw-inner)

      else:
        path = newPath()
        path.moveTo(x-outer,   y-outer)
        path.lineTo(x+w+outer, y-outer,  )
        path.lineTo(x+w+outer, y+h+outer,)
        path.lineTo(x-outer,   y+h+outer,)
        path.lineTo(x-outer,   y-outer,  )
        path.closePath()

        path.moveTo(x+inner,   y+inner)
        path.lineTo(x+inner,   y+h-inner)
        path.lineTo(x+w-inner, y+h-inner)
        path.lineTo(x+w-inner, y+inner)
        path.lineTo(x+inner,   y+inner)
        path.closePath()

      strokeMaskCtx = strokeMaskCtx.fillPath(
        path,
        white,
        mat
      )

  of "VECTOR", "STAR", "ELLIPSE", "LINE", "REGULAR_POLYGON":
    if node.fills.len > 0:
      fillMaskCtx = newImage(w, h)
      var geometryCtx = newImage(w, h)
      for geometry in node.fillGeometry:
        geometryCtx = geometryCtx.fillPath(
          geometry.path,
          white,
          mat
        )
        fillMaskCtx = fillMaskCtx.draw(geometryCtx)

    if node.strokes.len > 0:
      strokeMaskCtx = newImage(w, h)
      for geometry in node.strokeGeometry:
        strokeMaskCtx = strokeMaskCtx.fillPath(
          geometry.path,
          white,
          mat
        )

  of "TEXT":

    func hAlignCase(s: string): HAlignMode =
      case s
      of "CENTER": return Center
      of "LEFT": return Left
      of "RIGHT": return Right
      else: return Left

    func vAlignCase(s: string): VAlignMode =
      case s
      of "CENTER": return Middle
      of "TOP": return Top
      of "BOTTOM": return Bottom
      else: Top

    let pos = vec2(mat[2, 0], mat[2, 1])

    var font: Font
    if node.style.fontPostScriptName notin typefaceCache:
      if node.style.fontPostScriptName == "":
        node.style.fontPostScriptName = node.style.fontFamily & "-Regular"

      downloadFont(node.style.fontPostScriptName)
      font = readFontTtf("fonts/" & node.style.fontPostScriptName & ".ttf")
      typefaceCache[node.style.fontPostScriptName] = font.typeface
    else:
      font = Font()
      font.typeface = typefaceCache[node.style.fontPostScriptName]
    font.size = node.style.fontSize
    font.lineHeight = node.style.lineHeightPx

    var wrap = false
    if node.style.textAutoResize == "HEIGHT":
      wrap = true

    var kern = true
    if node.style.opentypeFlags != nil:
      if node.style.opentypeFlags.KERN == 0:
        kern = false

    let layout = font.typeset(
      text = node.characters,
      pos = pos,
      size = node.size,
      hAlign = hAlignCase(node.style.textAlignHorizontal),
      vAlign = vAlignCase(node.style.textAlignVertical),
      clip = false,
      wrap = wrap,
      kern = kern,
      textCase = parseTextCase(node.style.textCase),
    )
    fillMaskCtx = newImage(w, h)
    fillMaskCtx.drawText(layout)

    # if node.strokes.len > 0:
    #   strokeMaskCtx = fillMaskCtx.outlineBorder2(node.strokeWeight.int)

  of "BOOLEAN_OPERATION":
    drawChildren(node)

    fillMaskCtx = newImage(w, h)
    for i, child in node.children:
      let blendMode =
        if i == 0:
          bmNormal
        else:
          case node.booleanOperation
            of "SUBTRACT":
              bmSubtractMask
            of "INTERSECT":
              bmIntersectMask
            of "EXCLUDE":
              bmExcludeMask
            of "UNION":
              bmNormal
            else:
              bmNormal
      fillMaskCtx = fillMaskCtx.draw(
        child.pixels,
        child.pixelBox.xy - node.pixelBox.xy,
        blendMode
      )

  else:
    echo "Not supported node type: ", node.`type`

  for fill in node.fills:
    applyPaint(fillMaskCtx, fill, node, mat)

  for stroke in node.strokes:
   applyPaint(strokeMaskCtx, stroke, node, mat)

  for effect in node.effects:
    if effect.`type` == "INNER_SHADOW":
      applyInnerShadowEffect(effect, node, fillMaskCtx)

  if node.children.len > 0:
    drawChildren(node)

  #   var
  #     haveMask = false
  #     haveChildren = false
  #   for child in node.children:
  #     if child.isMask:
  #       haveMask = true
  #     else:
  #       haveChildren = true

  #   if haveMask and haveChildren:
  #     # If there are children and a mask.
  #     var nodeMaskLayer = newImage(node.pixels.width, node.pixels.height)
  #     for child in node.children:
  #       if child.isMask:
  #         if child.pixels != nil:
  #           nodeMaskLayer.draw(
  #             child.pixels,
  #             child.pixelBox.xy - node.pixelBox.xy,
  #             Normal
  #           )
  #     var childLayer = newImage(node.pixels.width, node.pixels.height)
  #     for child in node.children:
  #       if child.pixels != nil:
  #         if not child.isMask:
  #           childLayer.draw(
  #             child.pixels,
  #             child.pixelBox.xy - node.pixelBox.xy,
  #             parseBlendMode(child.blendMode),
  #           )
  #     childLayer.draw(
  #       nodeMaskLayer,
  #       blendMode = Mask,
  #     )
  #     node.pixels.draw(
  #       childLayer,
  #       blendMode = Normal,
  #     )

  #   elif haveChildren:
  #     # If its just children.
  #     for child in node.children:
  #       assert node.pixels != nil
  #       if child.pixels != nil:
  #         node.pixels.draw(
  #           child.pixels,
  #           child.pixelBox.xy - node.pixelBox.xy,
  #           parseBlendMode(child.blendMode),
  #         )

  for effect in node.effects:
    if effect.`type` == "DROP_SHADOW":
      if node.pixels != nil:
        applyDropShadowEffect(effect, node)
    elif effect.`type` == "LAYER_BLUR":
      if node.pixels != nil:
        applyLayerBlurEffect(effect, node)

  # Apply node.opacity to alpha
  if node.opacity != 1.0:
    node.pixels = node.pixels.applyOpacity(node.opacity)

  node.dirty = false
  assert node.pixels != nil

  #node.pixels.writeFile("tmp/" & node.name & ".png")

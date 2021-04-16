part of image_crop;

const _kCropGridColumnCount = 3;
const _kCropGridRowCount = 3;
const _kCropGridColor = Color.fromRGBO(0xd0, 0xd0, 0xd0, 0.9);
const _kCropOverlayActiveOpacity = 0.3;
const _kCropOverlayInactiveOpacity = 0.7;
const _kCropHandleColor = Color.fromRGBO(0xd0, 0xd0, 0xd0, 1.0);
const _kCropHandleSize = 10.0;
const _kCropHandleHitSize = 48.0;
const _kCropMinFraction = 0.1;

enum _CropAction { none, moving, cropping, scaling }
enum _CropHandleSide { none, topLeft, topRight, bottomLeft, bottomRight }


class Crop extends StatefulWidget
{
  final ImageProvider image;
  final double aspectRatio;
  final double maximumScale;
  final bool alwaysShowGrid;
  final bool showHandles;
  final EdgeInsets defaultPadding;
  final ImageErrorListener onImageError;

  const Crop({
    Key key,
    this.image,
    this.aspectRatio,
    this.maximumScale = 2.0,
    this.alwaysShowGrid = false,
    this.showHandles = true,
    this.defaultPadding = EdgeInsets.zero,
    this.onImageError,
  })
  : assert(image != null)
  , assert(maximumScale != null)
  , assert(alwaysShowGrid != null)
  , assert(showHandles != null)
  , assert(defaultPadding != null)
  , super(key: key);

  Crop.file(File file, {
    Key key,
    double scale = 1.0,
    this.aspectRatio,
    this.maximumScale = 2.0,
    this.alwaysShowGrid = false,
    this.showHandles = true,
    this.defaultPadding = EdgeInsets.zero,
    this.onImageError,
  })
  : image = FileImage(file, scale: scale)
  , assert(maximumScale != null)
  , assert(alwaysShowGrid != null)
  , assert(showHandles != null)
  , assert(defaultPadding != null)
  , super(key: key);

  Crop.asset(String assetName, {
    Key key,
    AssetBundle bundle,
    String package,
    this.aspectRatio,
    this.maximumScale = 2.0,
    this.alwaysShowGrid = false,
    this.showHandles = true,
    this.defaultPadding = EdgeInsets.zero,
    this.onImageError,
  })
  : image = AssetImage(assetName, bundle: bundle, package: package)
  , assert(maximumScale != null)
  , assert(alwaysShowGrid != null)
  , assert(showHandles != null)
  , assert(defaultPadding != null)
  , super(key: key);

  @override
  State<StatefulWidget> createState() => CropState();

  static CropState of(BuildContext context) =>
    context.findAncestorStateOfType<CropState>();
}


class CropState extends State<Crop>
  with TickerProviderStateMixin, Drag
{
  double get scale => _area.shortestSide / _scale;

  Rect get area => _view.isEmpty
    ? null
    : Rect.fromLTWH(
        _area.left * _view.width / _scale - _view.left,
        _area.top * _view.height / _scale - _view.top,
        _area.width * _view.width / _scale,
        _area.height * _view.height / _scale,
      );

  @override
  void initState()
  {
    super.initState();
    _area = Rect.zero;
    _view = Rect.zero;
    _scale = 1.0;
    _ratio = 1.0;
    _action = _CropAction.none;
    _handle = _CropHandleSide.none;
    _activeController = AnimationController(
      vsync: this,
      value: widget.alwaysShowGrid ? 1.0 : 0.0,
    )
      ..addListener(() => setState(() {}));
    _settleController = AnimationController(vsync: this)
      ..addListener(_settleAnimationChanged);
  }

  @override
  void dispose()
  {
    _imageStream?.removeListener(_imageListener);
    _activeController.dispose();
    _settleController.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies()
  {
    super.didChangeDependencies();
    _getImage();
  }

  @override
  void didUpdateWidget(Crop oldWidget)
  {
    super.didUpdateWidget(oldWidget);
    if (widget.image != oldWidget.image) {
      _getImage();
    } else if (widget.aspectRatio != oldWidget.aspectRatio) {
      _area = _calculateDefaultArea(
        viewWidth: _view.width,
        viewHeight: _view.height,
        imageWidth: _image?.width,
        imageHeight: _image?.height,
      );
    }
    if (widget.alwaysShowGrid != oldWidget.alwaysShowGrid) {
      if (widget.alwaysShowGrid) {
        _activate();
      } else {
        _deactivate();
      }
    }
  }

  @override
  Widget build(BuildContext context)
  {
    return ConstrainedBox(
      constraints: const BoxConstraints.expand(),
      child: Listener(
        onPointerDown: (event) => _pointers++,
        onPointerUp: (event) => _pointers = 0,
        child: LayoutBuilder(builder: (context, constraints) {
          final newSize = constraints.biggest;
          if (_size != newSize) {
            _size = newSize;
            Future(_updateView);
          }
          return GestureDetector(
            key: _surfaceKey,
            behavior: HitTestBehavior.opaque,
            onScaleStart: _isEnabled ? _handleScaleStart : null,
            onScaleUpdate: _isEnabled ? _handleScaleUpdate : null,
            onScaleEnd: _isEnabled ? _handleScaleEnd : null,
            child: CustomPaint(
              painter: _CropPainter(
                image: _image,
                ratio: _ratio,
                view: _view,
                area: _area,
                scale: _scale,
                active: _activeController.value,
                showHandles: widget.showHandles,
              ),
            ),
          );
        }),
      ),
    );
  }

  void _activate()
  {
    _activeController.animateTo(
      1.0,
      curve: Curves.fastOutSlowIn,
      duration: const Duration(milliseconds: 250),
    );
  }

  void _deactivate()
  {
    if (!widget.alwaysShowGrid) {
      _activeController.animateTo(
        0.0,
        curve: Curves.fastOutSlowIn,
        duration: const Duration(milliseconds: 250),
      );
    }
  }

  void _handleScaleStart(ScaleStartDetails details)
  {
    _activate();
    _settleController.stop(canceled: false);
    _action = _CropAction.none;
    _startLocalPoint = _getLocalPoint(details.focalPoint);
    _handle = _hitCropHandle(_startLocalPoint);
    final areaRect = _areaRect;
    switch (_handle) {
      case _CropHandleSide.topLeft:
        _startHandleOffset = _startLocalPoint - areaRect.topLeft; break;
      case _CropHandleSide.topRight:
        _startHandleOffset = _startLocalPoint - areaRect.topRight; break;
      case _CropHandleSide.bottomLeft:
        _startHandleOffset = _startLocalPoint - areaRect.bottomLeft; break;
      case _CropHandleSide.bottomRight:
        _startHandleOffset = _startLocalPoint - areaRect.bottomRight; break;
      case _CropHandleSide.none:
        _startHandleOffset = null; break;
    }
    _startScale = _scale;
    _startView = _view;
  }

  void _handleScaleUpdate(ScaleUpdateDetails details)
  {
    if (_action == _CropAction.none) {
      if (_handle == _CropHandleSide.none) {
        _action = _pointers == 2 ? _CropAction.scaling : _CropAction.moving;
      } else {
        _action = _CropAction.cropping;
      }
    }

    if (_action == _CropAction.cropping) {
      final localPoint = _getLocalPoint(details.focalPoint);
      final handlePoint = localPoint - _startHandleOffset;
      _updateArea(handlePoint);
    } else if (_action == _CropAction.moving) {
      final localPoint = _getLocalPoint(details.focalPoint);
      final offset = localPoint - _startLocalPoint;
      final viewOffset = _startView.topLeft + Offset(
        offset.dx / (_image.width * _scale * _ratio),
        offset.dy / (_image.height * _scale * _ratio),
      );
      setState(() {
        _view = viewOffset & _view.size;
      });
    } else if (_action == _CropAction.scaling) {
      setState(() {
        _scale = _startScale * details.scale;

        final dx = _size.width *
            (1.0 - details.scale) /
            (_image.width * _scale * _ratio);
        final dy = _size.height *
            (1.0 - details.scale) /
            (_image.height * _scale * _ratio);

        _view = Rect.fromLTWH(
          _startView.left + dx / 2,
          _startView.top + dy / 2,
          _startView.width,
          _startView.height,
        );
      });
    }
  }

  void _handleScaleEnd(ScaleEndDetails details)
  {
    _deactivate();

    final targetScale = _scale.clamp(_minimumScale, _maximumScale);
    _scaleTween = Tween<double>(
      begin: _scale,
      end: targetScale,
    );

    _startView = _view;
    _viewTween = RectTween(
      begin: _view,
      end: _getViewInBoundaries(targetScale),
    );

    _settleController.value = 0.0;
    _settleController.animateTo(
      1.0,
      curve: Curves.fastOutSlowIn,
      duration: const Duration(milliseconds: 350),
    );
  }

  void _settleAnimationChanged()
  {
    setState(() {
      _scale = _scaleTween.transform(_settleController.value);
      _view = _viewTween.transform(_settleController.value);
    });
  }

  _CropHandleSide _hitCropHandle(Offset localPoint)
  {
    if (!widget.showHandles) return _CropHandleSide.none;

    final areaRect = _areaRect;

    if (Rect.fromLTWH(
      areaRect.left - _kCropHandleHitSize / 2,
      areaRect.top - _kCropHandleHitSize / 2,
      _kCropHandleHitSize,
      _kCropHandleHitSize,
    ).contains(localPoint)) {
      return _CropHandleSide.topLeft;
    }

    if (Rect.fromLTWH(
      areaRect.right - _kCropHandleHitSize / 2,
      areaRect.top - _kCropHandleHitSize / 2,
      _kCropHandleHitSize,
      _kCropHandleHitSize,
    ).contains(localPoint)) {
      return _CropHandleSide.topRight;
    }

    if (Rect.fromLTWH(
      areaRect.left - _kCropHandleHitSize / 2,
      areaRect.bottom - _kCropHandleHitSize / 2,
      _kCropHandleHitSize,
      _kCropHandleHitSize,
    ).contains(localPoint)) {
      return _CropHandleSide.bottomLeft;
    }

    if (Rect.fromLTWH(
      areaRect.right - _kCropHandleHitSize / 2,
      areaRect.bottom - _kCropHandleHitSize / 2,
      _kCropHandleHitSize,
      _kCropHandleHitSize,
    ).contains(localPoint)) {
      return _CropHandleSide.bottomRight;
    }

    return _CropHandleSide.none;
  }

  void _updateImage(ImageInfo imageInfo, bool synchronousCall)
  {
    WidgetsBinding.instance.addPostFrameCallback((timeStamp) {
      setState(() {
        _image = imageInfo.image;
        _scale = imageInfo.scale;
        _updateView();
      });
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _updateView()
  {
    final oldScale = _scale;
    _scale = 1.0;
    _ratio = max(
      _size.width / _image.width,
      _size.height / _image.height,
    );
    final viewWidth =
      _size.width / (_image.width * _scale * _ratio);
    final viewHeight =
      _size.height / (_image.height * _scale * _ratio);
    _area = _calculateDefaultArea(
      viewWidth: viewWidth,
      viewHeight: viewHeight,
      imageWidth: _image.width,
      imageHeight: _image.height,
    );
    _view = Rect.fromLTWH(
      (viewWidth - 1.0) / 2,
      (viewHeight - 1.0) / 2,
      viewWidth,
      viewHeight,
    );
    if (oldScale != null) _scale = oldScale.clamp(_minimumScale, _maximumScale);
    _view = _getViewInBoundaries(_scale);
    setState(() {});
  }

  void _updateArea(Offset handlePoint)
  {
    var areaLeft = _area.left;
    var areaBottom = _area.bottom;
    var areaTop = _area.top;
    var areaRight = _area.right;
    bool left, top;
    switch (_handle) {
      case _CropHandleSide.none: return;
      case _CropHandleSide.topLeft:
        areaTop = handlePoint.dy / _size.height;
        areaLeft = handlePoint.dx / _size.width;
        top = true;
        left = true;
        break;
      case _CropHandleSide.topRight:
        areaTop = handlePoint.dy / _size.height;
        areaRight = handlePoint.dx / _size.width;
        top = true;
        left = false;
        break;
      case _CropHandleSide.bottomLeft:
        areaBottom = handlePoint.dy / _size.height;
        areaLeft = handlePoint.dx / _size.width;
        top = false;
        left = true;
        break;
      case _CropHandleSide.bottomRight:
        areaBottom = handlePoint.dy / _size.height;
        areaRight = handlePoint.dx / _size.width;
        top = false;
        left = false;
        break;
    }

    if (widget.showHandles) {
      const padding = _kCropHandleSize / 2;
      if (areaLeft * _size.width < padding) {
        areaLeft = padding / _size.width;
      }
      if (areaRight * _size.width > _size.width - padding) {
        areaRight = (_size.width - padding) / _size.width;
      }
      if (areaTop * _size.height < padding) {
        areaTop = padding / _size.height;
      }
      if (areaBottom * _size.height > _size.height - padding) {
        areaBottom = (_size.height - padding) / _size.height;
      }
    }
    // Ensure minimum rectangle
    if (areaRight - areaLeft < _kCropMinFraction) {
      if (left) {
        areaLeft = areaRight - _kCropMinFraction;
      } else {
        areaRight = areaLeft + _kCropMinFraction;
      }
    }
    if (areaBottom - areaTop < _kCropMinFraction) {
      if (top) {
        areaTop = areaBottom - _kCropMinFraction;
      } else {
        areaBottom = areaTop + _kCropMinFraction;
      }
    }

    final aRatio = (_image.width * _view.width) / (_image.height * _view.height);
    final size = Size(areaRight - areaLeft, areaBottom - areaTop);
    final aspect = size.aspectRatio * aRatio;
    if (aspect > _aspectRatio) {
      final width = size.width * _aspectRatio / aspect;
      if (left) {
        areaLeft += size.width - width;
      } else {
        areaRight -= size.width - width;
      }
    } else if (aspect < _aspectRatio) {
      final height = size.height * aspect / _aspectRatio;
      if (top) {
        areaTop += size.height - height;
      } else {
        areaBottom -= size.height - height;
      }
    }

    setState(() {
      _area = Rect.fromLTRB(areaLeft, areaTop, areaRight, areaBottom);
    });
  }

  Rect _calculateDefaultArea({
    int imageWidth,
    int imageHeight,
    double viewWidth,
    double viewHeight,
  })
  {
    if (imageWidth == null || imageHeight == null) {
      return Rect.zero;
    }
    double height;
    double width;
    if (_aspectRatio < 1) {
      height = 1.0;
      width = _aspectRatio * imageHeight * viewHeight * height
        / imageWidth
        / viewWidth;
      if (width > 1.0) {
        width = 1.0;
        height = imageWidth * viewWidth * width
          / (imageHeight * viewHeight * _aspectRatio);
      }
    } else {
      width = 1.0;
      height = imageWidth * viewWidth * width
        / (imageHeight * viewHeight * _aspectRatio);
      if (height > 1.0) {
        height = 1.0;
        width = _aspectRatio * imageHeight * viewHeight * height
          / imageWidth
          / viewWidth;
      }
    }
    final rect = Rect.fromLTWH(
      (1.0 - width) / 2, (1.0 - height) / 2, width, height
    );
    final EdgeInsets padding = widget.defaultPadding.clamp(
      widget.showHandles
        ? const EdgeInsets.all(_kCropHandleSize / 2)
        : EdgeInsets.zero,
      EdgeInsets.symmetric(
        vertical: max(_size.width / 2 - 2, 0.0),
        horizontal: max(_size.height / 2 - 2, 0.0),
      )
    );
    if (padding.horizontal <= 0 && padding.vertical <= 0) {
      return rect;
    }
    final deflated = padding.deflateRect(Rect.fromLTWH(
      rect.left * _size.width,
      rect.top * _size.height,
      rect.width * _size.width,
      rect.height * _size.height
    ));
    return Rect.fromLTWH(
      deflated.left / _size.width,
      deflated.top / _size.height,
      deflated.width / _size.width,
      deflated.height / _size.height
    );
  }

  void _getImage({ bool force = false })
  {
    final oldImageStream = _imageStream;
    _imageStream = widget.image.resolve(createLocalImageConfiguration(context));
    if (_imageStream.key != oldImageStream?.key || force) {
      oldImageStream?.removeListener(_imageListener);
      _imageListener =
          ImageStreamListener(_updateImage, onError: widget.onImageError);
      _imageStream.addListener(_imageListener);
    }
  }

  Rect _getViewInBoundaries(double scale)
  {
    return Offset(
      max(
        min(
          _view.left,
          _area.left * _view.width / scale,
        ),
        _area.right * _view.width / scale - 1.0,
      ),
      max(
        min(
          _view.top,
          _area.top * _view.height / scale,
        ),
        _area.bottom * _view.height / scale - 1.0,
      ),
    )
    & _view.size;
  }

  Offset _getLocalPoint(Offset point)
  {
    final RenderBox box = _surfaceKey.currentContext.findRenderObject();
    return box.globalToLocal(point);
  }

  bool get _isEnabled => !_view.isEmpty && _image != null;

  double get _aspectRatio => widget.aspectRatio ?? 1.0;

  double get _maximumScale => widget.maximumScale;

  double get _minimumScale
  {
    final scaleX = _size.width * _area.width / (_image.width * _ratio);
    final scaleY = _size.height * _area.height / (_image.height * _ratio);
    return min(_maximumScale, max(scaleX, scaleY));
  }

  Rect get _areaRect => Rect.fromLTWH(
    _area.left * _size.width,
    _area.top * _size.height,
    _area.width * _size.width,
    _area.height * _size.height,
  );

  AnimationController _activeController;
  AnimationController _settleController;
  ImageStream _imageStream;
  ui.Image _image;
  Size _size;
  double _scale;
  double _ratio;
  Rect _view;
  Rect _area;
  _CropAction _action;
  _CropHandleSide _handle;
  Offset _startLocalPoint;
  Offset _startHandleOffset;
  double _startScale;
  Rect _startView;
  Tween<Rect> _viewTween;
  Tween<double> _scaleTween;
  ImageStreamListener _imageListener;

  /// Counting pointers(number of user fingers on screen)
  int _pointers = 0;

  final _surfaceKey = GlobalKey();
}


class _CropPainter extends CustomPainter
{
  final ui.Image image;
  final Rect view;
  final double ratio;
  final Rect area;
  final double scale;
  final double active;
  final bool showHandles;

  _CropPainter({
    this.image,
    this.view,
    this.ratio,
    this.area,
    this.scale,
    this.active,
    this.showHandles,
  });

  @override
  bool shouldRepaint(_CropPainter oldDelegate)
  {
    return oldDelegate.image != image ||
        oldDelegate.view != view ||
        oldDelegate.ratio != ratio ||
        oldDelegate.area != area ||
        oldDelegate.active != active ||
        oldDelegate.scale != scale ||
        oldDelegate.showHandles != showHandles;
  }

  @override
  void paint(Canvas canvas, Size size)
  {
    final rect = Rect.fromLTWH(0.0, 0.0, size.width, size.height);

    final paint = Paint()..isAntiAlias = false;

    if (image != null) {
      final src = Rect.fromLTWH(
        0.0,
        0.0,
        image.width.toDouble(),
        image.height.toDouble(),
      );
      final dst = Rect.fromLTWH(
        view.left * image.width * scale * ratio,
        view.top * image.height * scale * ratio,
        image.width * scale * ratio,
        image.height * scale * ratio,
      );

      canvas.save();
      canvas.clipRect(Rect.fromLTWH(0.0, 0.0, rect.width, rect.height));
      canvas.drawImageRect(image, src, dst, paint);
      canvas.restore();
    }

    paint.color = Color.fromRGBO(
        0x0,
        0x0,
        0x0,
        _kCropOverlayActiveOpacity * active +
            _kCropOverlayInactiveOpacity * (1.0 - active));
    final boundaries = Rect.fromLTWH(
      rect.width * area.left,
      rect.height * area.top,
      rect.width * area.width,
      rect.height * area.height,
    );
    canvas.drawRect(Rect.fromLTRB(0.0, 0.0, rect.width, boundaries.top), paint);
    canvas.drawRect(
        Rect.fromLTRB(0.0, boundaries.bottom, rect.width, rect.height), paint);
    canvas.drawRect(
        Rect.fromLTRB(0.0, boundaries.top, boundaries.left, boundaries.bottom),
        paint);
    canvas.drawRect(
        Rect.fromLTRB(
            boundaries.right, boundaries.top, rect.width, boundaries.bottom),
        paint);

    if (!boundaries.isEmpty) {
      _drawGrid(canvas, boundaries);
      if (showHandles) _drawHandles(canvas, boundaries);
    }
  }

  void _drawHandles(Canvas canvas, Rect boundaries)
  {
    final paint = Paint()
      ..isAntiAlias = true
      ..color = _kCropHandleColor;

    canvas.drawOval(
      Rect.fromLTWH(
        boundaries.left - _kCropHandleSize / 2,
        boundaries.top - _kCropHandleSize / 2,
        _kCropHandleSize,
        _kCropHandleSize,
      ),
      paint,
    );

    canvas.drawOval(
      Rect.fromLTWH(
        boundaries.right - _kCropHandleSize / 2,
        boundaries.top - _kCropHandleSize / 2,
        _kCropHandleSize,
        _kCropHandleSize,
      ),
      paint,
    );

    canvas.drawOval(
      Rect.fromLTWH(
        boundaries.right - _kCropHandleSize / 2,
        boundaries.bottom - _kCropHandleSize / 2,
        _kCropHandleSize,
        _kCropHandleSize,
      ),
      paint,
    );

    canvas.drawOval(
      Rect.fromLTWH(
        boundaries.left - _kCropHandleSize / 2,
        boundaries.bottom - _kCropHandleSize / 2,
        _kCropHandleSize,
        _kCropHandleSize,
      ),
      paint,
    );
  }

  void _drawGrid(Canvas canvas, Rect boundaries)
  {
    if (active == 0.0) return;

    final paint = Paint()
      ..isAntiAlias = false
      ..color = _kCropGridColor.withOpacity(_kCropGridColor.opacity * active)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    final path = Path()
      ..moveTo(boundaries.left, boundaries.top)
      ..lineTo(boundaries.right, boundaries.top)
      ..lineTo(boundaries.right, boundaries.bottom)
      ..lineTo(boundaries.left, boundaries.bottom)
      ..lineTo(boundaries.left, boundaries.top);

    for (var column = 1; column < _kCropGridColumnCount; column++) {
      path
        ..moveTo(
            boundaries.left + column * boundaries.width / _kCropGridColumnCount,
            boundaries.top)
        ..lineTo(
            boundaries.left + column * boundaries.width / _kCropGridColumnCount,
            boundaries.bottom);
    }

    for (var row = 1; row < _kCropGridRowCount; row++) {
      path
        ..moveTo(boundaries.left,
            boundaries.top + row * boundaries.height / _kCropGridRowCount)
        ..lineTo(boundaries.right,
            boundaries.top + row * boundaries.height / _kCropGridRowCount);
    }

    canvas.drawPath(path, paint);
  }
}

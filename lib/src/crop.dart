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
const _kCropBorder = RoundedRectangleBorder();


enum _CropAction { none, moving, cropping, scaling }

enum _CropHandleSide { none, topLeft, topRight, bottomLeft, bottomRight }


class Crop extends StatefulWidget
{
  final ImageProvider image;
  final double? aspectRatio;
  final double maximumScale;
  final bool alwaysShowGrid;
  final bool showHandles;
  final EdgeInsets defaultPadding;
  final ShapeBorder cropBorder;
  final ImageErrorListener? onImageError;

  const Crop({
    super.key,
    required this.image,
    this.aspectRatio,
    this.maximumScale = 2.0,
    this.alwaysShowGrid = false,
    this.showHandles = true,
    this.defaultPadding = EdgeInsets.zero,
    this.cropBorder = _kCropBorder,
    this.onImageError,
  });

  Crop.file(File file, {
    super.key,
    double scale = 1.0,
    this.aspectRatio,
    this.maximumScale = 2.0,
    this.alwaysShowGrid = false,
    this.showHandles = true,
    this.defaultPadding = EdgeInsets.zero,
    this.cropBorder = _kCropBorder,
    this.onImageError,
  })
  : image = FileImage(file, scale: scale);

  Crop.asset(String assetName, {
    super.key,
    AssetBundle? bundle,
    String? package,
    this.aspectRatio,
    this.maximumScale = 2.0,
    this.alwaysShowGrid = false,
    this.showHandles = true,
    this.defaultPadding = EdgeInsets.zero,
    this.cropBorder = _kCropBorder,
    this.onImageError,
  })
  : image = AssetImage(assetName, bundle: bundle, package: package);

  @override
  State<StatefulWidget> createState() => CropState();

  static CropState? of(final BuildContext context) =>
      context.findAncestorStateOfType<CropState>();
}


class CropState extends State<Crop> with TickerProviderStateMixin, Drag
{
  double get scale => _area.shortestSide / _scale;

  Rect? get area => _view.isEmpty
    ? null
    : Rect.fromLTWH(
        max(_area.left * _view.width / _scale - _view.left, 0),
        max(_area.top * _view.height / _scale - _view.top, 0),
        _area.width * _view.width / _scale,
        _area.height * _view.height / _scale,
      );

  @override
  void initState()
  {
    super.initState();
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
    final listener = _imageListener;
    if (listener != null) {
      _imageStream?.removeListener(listener);
    }
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
  void didUpdateWidget(final Crop oldWidget)
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
  Widget build(final BuildContext context)
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
            if (_image != null) Future(_updateView);
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
                border: widget.cropBorder,
              ),
            ),
          );
        }),
      ),
    );
  }

  void _activate()
  {
    _activeController.animateTo(1.0,
      curve: Curves.fastOutSlowIn,
      duration: const Duration(milliseconds: 250),
    );
  }

  void _deactivate()
  {
    if (!widget.alwaysShowGrid) {
      _activeController.animateTo(0.0,
        curve: Curves.fastOutSlowIn,
        duration: const Duration(milliseconds: 250),
      );
    }
  }

  void _handleScaleStart(final ScaleStartDetails details)
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
        _startHandleOffset = Offset.zero; break;
    }
    _startScale = _scale;
    _startView = _view;
  }

  void _handleScaleUpdate(final ScaleUpdateDetails details)
  {
    final image = _image;
    if (image == null) return;
    final size = _size;
    if (size == null) return;

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
        offset.dx / (image.width * _scale * _ratio),
        offset.dy / (image.height * _scale * _ratio),
      );
      setState(() => _view = viewOffset & _view.size);
    } else if (_action == _CropAction.scaling) {
      setState(() {
        _scale = _startScale * details.scale;

        final dx = size.width
          * (1.0 - details.scale)
          / (image.width * _scale * _ratio);
        final dy = size.height
          * (1.0 - details.scale)
          / (image.height * _scale * _ratio);

        _view = Rect.fromLTWH(
          _startView.left + dx / 2,
          _startView.top + dy / 2,
          _startView.width,
          _startView.height,
        );
      });
    }
  }

  void _handleScaleEnd(final ScaleEndDetails details)
  {
    _deactivate();
    final minimumScale = _minimumScale;
    if (minimumScale == null) return;

    final targetScale = _scale.clamp(minimumScale, _maximumScale);
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
    _settleController.animateTo(1.0,
      curve: Curves.fastOutSlowIn,
      duration: const Duration(milliseconds: 350),
    );
  }

  void _settleAnimationChanged()
  {
    setState(() {
      _scale = _scaleTween.transform(_settleController.value);
      final nextView = _viewTween.transform(_settleController.value);
      if (nextView != null) {
        _view = nextView;
      }
    });
  }

  _CropHandleSide _hitCropHandle(final Offset? localPoint)
  {
    if (!widget.showHandles || localPoint == null) return _CropHandleSide.none;

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

  void _updateImage(final ImageInfo imageInfo, final bool synchronousCall)
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
    final image = _image;
    if (image == null) return;
    final size = _size;
    if (size == null) return;

    final oldScale = _scale;
    _scale = 1.0;
    _ratio = max(
      size.width / image.width,
      size.height / image.height,
    );
    final viewWidth =
      size.width / (image.width * _scale * _ratio);
    final viewHeight =
      size.height / (image.height * _scale * _ratio);
    _area = _calculateDefaultArea(
      viewWidth: viewWidth,
      viewHeight: viewHeight,
      imageWidth: image.width,
      imageHeight: image.height,
    );
    _view = Rect.fromLTWH(
      (viewWidth - 1.0) / 2,
      (viewHeight - 1.0) / 2,
      viewWidth,
      viewHeight,
    );
    setState(() {
      _scale = oldScale.clamp(_minimumScale!, _maximumScale);
      _view = _getViewInBoundaries(_scale);
    });
  }

  void _updateArea(final Offset handlePoint)
  {
    final image = _image;
    if (image == null) return;
    final size = _size;
    if (size == null) return;

    var areaLeft = _area.left;
    var areaBottom = _area.bottom;
    var areaTop = _area.top;
    var areaRight = _area.right;
    bool left, top;
    switch (_handle) {
      case _CropHandleSide.none: return;
      case _CropHandleSide.topLeft:
        areaTop = handlePoint.dy / size.height;
        areaLeft = handlePoint.dx / size.width;
        top = true;
        left = true;
        break;
      case _CropHandleSide.topRight:
        areaTop = handlePoint.dy / size.height;
        areaRight = handlePoint.dx / size.width;
        top = true;
        left = false;
        break;
      case _CropHandleSide.bottomLeft:
        areaBottom = handlePoint.dy / size.height;
        areaLeft = handlePoint.dx / size.width;
        top = false;
        left = true;
        break;
      case _CropHandleSide.bottomRight:
        areaBottom = handlePoint.dy / size.height;
        areaRight = handlePoint.dx / size.width;
        top = false;
        left = false;
        break;
    }

    if (widget.showHandles) {
      const padding = _kCropHandleSize / 2;
      if (areaLeft * size.width < padding) {
        areaLeft = padding / size.width;
      }
      if (areaRight * size.width > size.width - padding) {
        areaRight = (size.width - padding) / size.width;
      }
      if (areaTop * size.height < padding) {
        areaTop = padding / size.height;
      }
      if (areaBottom * size.height > size.height - padding) {
        areaBottom = (size.height - padding) / size.height;
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

    final aRatio = (image.width * _view.width) / (image.height * _view.height);
    final areaSize = Size(areaRight - areaLeft, areaBottom - areaTop);
    final aspect = areaSize.aspectRatio * aRatio;
    if (aspect > _aspectRatio) {
      final width = areaSize.width * _aspectRatio / aspect;
      if (left) {
        areaLeft += areaSize.width - width;
      } else {
        areaRight -= areaSize.width - width;
      }
    } else if (aspect < _aspectRatio) {
      final height = areaSize.height * aspect / _aspectRatio;
      if (top) {
        areaTop += areaSize.height - height;
      } else {
        areaBottom -= areaSize.height - height;
      }
    }

    setState(() {
      _area = Rect.fromLTRB(areaLeft, areaTop, areaRight, areaBottom);
    });
  }

  Rect _calculateDefaultArea({
    required final int? imageWidth,
    required final int? imageHeight,
    required final double viewWidth,
    required final double viewHeight,
  })
  {
    final size = _size;
    if (size == null || imageWidth == null || imageHeight == null) {
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
    final padding = widget.defaultPadding.clamp(
      widget.showHandles
        ? const EdgeInsets.all(_kCropHandleSize / 2)
        : EdgeInsets.zero,
      EdgeInsets.symmetric(
        vertical: max(size.width / 2 - 2, 0.0),
        horizontal: max(size.height / 2 - 2, 0.0),
      )
    ) as EdgeInsets;
    if (padding.horizontal <= 0 && padding.vertical <= 0) {
      return rect;
    }
    final deflated = padding.deflateRect(Rect.fromLTWH(
      rect.left * size.width,
      rect.top * size.height,
      rect.width * size.width,
      rect.height * size.height,
    ));
    return Rect.fromLTWH(
      deflated.left / size.width,
      deflated.top / size.height,
      deflated.width / size.width,
      deflated.height / size.height,
    );
  }

  void _getImage({ final bool force = false })
  {
    final oldImageStream = _imageStream;
    final newImageStream = widget.image.resolve(
      createLocalImageConfiguration(context)
    );
    _imageStream = newImageStream;
    if (newImageStream.key != oldImageStream?.key || force) {
      final oldImageListener = _imageListener;
      if (oldImageListener != null) {
        oldImageStream?.removeListener(oldImageListener);
      }
      final newImageListener = ImageStreamListener(_updateImage,
        onError: widget.onImageError,
      );
      _imageListener = newImageListener;
      newImageStream.addListener(newImageListener);
    }
  }

  Rect _getViewInBoundaries(final double scale) => Offset(
    max(
      min(_view.left, _area.left * _view.width / scale),
      _area.right * _view.width / scale - 1.0,
    ),
    max(
      min(_view.top, _area.top * _view.height / scale),
      _area.bottom * _view.height / scale - 1.0,
    ),
  ) & _view.size;

  Offset _getLocalPoint(final Offset point)
  {
    final box = _surfaceKey.currentContext!.findRenderObject() as RenderBox;
    return box.globalToLocal(point);
  }

  bool get _isEnabled => !_view.isEmpty && _image != null;

  double get _aspectRatio => widget.aspectRatio ?? 1.0;

  double get _maximumScale => widget.maximumScale;

  double? get _minimumScale
  {
    final size = _size;
    if (size == null || _image == null) return null;
    final scaleX = size.width * _area.width / (_image!.width * _ratio);
    final scaleY = size.height * _area.height / (_image!.height * _ratio);
    return min(_maximumScale, max(scaleX, scaleY));
  }

  Rect get _areaRect => Rect.fromLTWH(
    _area.left * _size!.width,
    _area.top * _size!.height,
    _area.width * _size!.width,
    _area.height * _size!.height,
  );

  late double _startScale;
  late Rect _startView;
  late Offset _startLocalPoint;
  late Offset _startHandleOffset;
  late Tween<Rect?> _viewTween;
  late Tween<double> _scaleTween;

  /// The number of pointers (of user fingers on the screen).
  int _pointers = 0;

  double _scale = 1.0;
  double _ratio = 1.0;
  Rect _view = Rect.zero;
  Rect _area = Rect.zero;
  _CropAction _action = _CropAction.none;
  _CropHandleSide _handle = _CropHandleSide.none;

  Size? _size;
  ImageStream? _imageStream;
  ui.Image? _image;
  ImageStreamListener? _imageListener;

  late final AnimationController _activeController;
  late final AnimationController _settleController;

  final _surfaceKey = GlobalKey();
}


class _CropPainter extends CustomPainter
{
  final ui.Image? image;
  final Rect view;
  final double ratio;
  final Rect area;
  final double scale;
  final double active;
  final bool showHandles;
  final ShapeBorder border;

  _CropPainter({
    required this.image,
    required this.view,
    required this.ratio,
    required this.area,
    required this.scale,
    required this.active,
    required this.showHandles,
    required this.border,
  });

  @override
  bool shouldRepaint(final _CropPainter oldDelegate)
  {
    return oldDelegate.image != image
      || oldDelegate.view != view
      || oldDelegate.ratio != ratio
      || oldDelegate.area != area
      || oldDelegate.active != active
      || oldDelegate.scale != scale
      || oldDelegate.showHandles != showHandles
      || oldDelegate.border != border;
  }

  @override
  void paint(final Canvas canvas, final Size size)
  {
    final rect = Rect.fromLTWH(0.0, 0.0, size.width, size.height);

    final paint = Paint()..isAntiAlias = false;

    final image = this.image;
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

    paint.color = Color.fromRGBO(0x0, 0x0, 0x0,
      _kCropOverlayActiveOpacity * active
      + _kCropOverlayInactiveOpacity * (1.0 - active)
    );
    final boundaries = Rect.fromLTWH(
      rect.width * area.left,
      rect.height * area.top,
      rect.width * area.width,
      rect.height * area.height,
    );
    final path = border.getInnerPath(boundaries);
    canvas.saveLayer(null, paint);
    canvas.drawRect(rect, paint);
    canvas.drawPath(path, Paint()
      ..blendMode = BlendMode.clear
      ..style = PaintingStyle.fill
    );
    canvas.restore();

    if (boundaries.isEmpty == false) {
      _drawGrid(canvas, boundaries);
      if (showHandles) _drawHandles(canvas, boundaries);
    }
  }

  void _drawHandles(final Canvas canvas, final Rect boundaries)
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

  void _drawGrid(final Canvas canvas, final Rect boundaries)
  {
    if (active == 0.0) return;

    final paint = Paint()
      ..isAntiAlias = true
      ..color = _kCropGridColor.withOpacity(_kCropGridColor.opacity * active)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    final path = Path();
    final borderPath = border.getInnerPath(boundaries);

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

    canvas.save();
    canvas.clipPath(borderPath);
    canvas.drawPath(path, paint);
    canvas.restore();
    canvas.drawPath(borderPath, paint);
  }
}

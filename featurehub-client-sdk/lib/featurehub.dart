// These types appear in this library's own public signatures - the
// ClientContext.country/device/platform parameters, FeatureStateHolder.type
// and ClientFeatureRepository.notify - so consumers cannot use the SDK
// without them. Re-exported here so an application never has to declare a
// dependency on the generated API package just to name an argument.
export 'package:featurehub_client_api/api.dart'
    show
        FeatureState,
        FeatureValueType,
        SSEResultState,
        StrategyAttributeCountryName,
        StrategyAttributeDeviceName,
        StrategyAttributePlatformName;

export 'featurehub_config.dart';
export 'src/analytics_google.dart';
export 'src/client_context.dart';
export 'src/repository.dart';
export 'src/sse_client.dart'
    if (dart.library.io) 'src/sse_client_dartio.dart'
    if (dart.library.html) 'src/sse_client_darthtml.dart';

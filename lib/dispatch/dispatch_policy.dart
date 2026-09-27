class DispatchPolicy {
  final int maxAutoOfferEtaSeconds;
  final int etaToleranceSeconds;
  final int distanceToleranceMeters;

  final int maxAutoOfferAttempts;
  final int offerTimeoutSeconds;

  const DispatchPolicy({
    this.maxAutoOfferEtaSeconds = 600,
    this.etaToleranceSeconds = 180,
    this.distanceToleranceMeters = 500,
    this.maxAutoOfferAttempts = 3,
    this.offerTimeoutSeconds = 15,
  }) : assert(maxAutoOfferEtaSeconds > 0),
       assert(etaToleranceSeconds >= 0),
       assert(distanceToleranceMeters >= 0),
       assert(maxAutoOfferAttempts > 0),
       assert(offerTimeoutSeconds > 0);

  Duration get offerTimeout => Duration(seconds: offerTimeoutSeconds);
}

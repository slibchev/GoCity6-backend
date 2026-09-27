class DispatchPolicy {
  final int maxAutoOfferEtaSeconds;
  final int etaToleranceSeconds;
  final int distanceToleranceMeters;

  const DispatchPolicy({
    this.maxAutoOfferEtaSeconds = 600,
    this.etaToleranceSeconds = 180,
    this.distanceToleranceMeters = 500,
  }) : assert(maxAutoOfferEtaSeconds > 0),
       assert(etaToleranceSeconds >= 0),
       assert(distanceToleranceMeters >= 0);
}

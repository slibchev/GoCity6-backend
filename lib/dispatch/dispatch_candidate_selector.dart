import 'dispatch_candidate.dart';
import 'dispatch_policy.dart';

class DispatchCandidateSelector {
  final DispatchPolicy policy;

  const DispatchCandidateSelector({this.policy = const DispatchPolicy()});

  DispatchCandidate? select(List<DispatchCandidate> candidates) {
    final rankedCandidates = rank(candidates);

    if (rankedCandidates.isEmpty) {
      return null;
    }

    return rankedCandidates.first;
  }

  List<DispatchCandidate> rank(List<DispatchCandidate> candidates) {
    final autoOfferCandidates = candidates
        .where(
          (candidate) => candidate.etaSeconds <= policy.maxAutoOfferEtaSeconds,
        )
        .toList();

    if (autoOfferCandidates.isEmpty) {
      return const [];
    }

    final bestEtaSeconds = autoOfferCandidates
        .map((candidate) => candidate.etaSeconds)
        .reduce((a, b) => a < b ? a : b);

    final etaCandidates = autoOfferCandidates
        .where(
          (candidate) =>
              candidate.etaSeconds <=
              bestEtaSeconds + policy.etaToleranceSeconds,
        )
        .toList();

    final bestDistanceMeters = etaCandidates
        .map((candidate) => candidate.distanceMeters)
        .reduce((a, b) => a < b ? a : b);

    final distanceCandidates = etaCandidates
        .where(
          (candidate) =>
              candidate.distanceMeters <=
              bestDistanceMeters + policy.distanceToleranceMeters,
        )
        .toList();

    distanceCandidates.sort(_compareCandidates);

    return List.unmodifiable(distanceCandidates);
  }

  int _compareCandidates(DispatchCandidate a, DispatchCandidate b) {
    if (a.hasCustomerCancellationPriority !=
        b.hasCustomerCancellationPriority) {
      return a.hasCustomerCancellationPriority ? -1 : 1;
    }

    final queuePriorityComparison = a.queuePrioritySince.compareTo(
      b.queuePrioritySince,
    );

    if (queuePriorityComparison != 0) {
      return queuePriorityComparison;
    }

    final etaComparison = a.etaSeconds.compareTo(b.etaSeconds);

    if (etaComparison != 0) {
      return etaComparison;
    }

    final distanceComparison = a.distanceMeters.compareTo(b.distanceMeters);

    if (distanceComparison != 0) {
      return distanceComparison;
    }

    return a.driverId.compareTo(b.driverId);
  }
}

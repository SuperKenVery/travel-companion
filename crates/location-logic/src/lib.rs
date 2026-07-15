//! Deterministic GPS/UWB presentation logic. Distance and direction are chosen
//! independently so a distance-only UWB update never freezes an old arrow.

use model::LocationSample;
use serde::{Deserialize, Serialize};

const EARTH_RADIUS_M: f64 = 6_371_008.8;

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum RelativeSource {
    Gps,
    Uwb,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UwbObservation {
    pub distance_m: Option<f64>,
    /// Device-relative direction in radians. It may be absent while distance is
    /// still available and accurate.
    pub direction_radians: Option<f64>,
    pub observed_at_ms: i64,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SourcedMeasurement {
    pub value: f64,
    pub source: RelativeSource,
    pub observed_at_ms: i64,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RelativeLocation {
    pub distance_m: SourcedMeasurement,
    pub direction_radians: SourcedMeasurement,
    pub horizontal_accuracy_m: f64,
    pub stale: bool,
    pub sample_age_ms: i64,
}

#[derive(Clone, Copy, Debug)]
pub struct FusionPolicy {
    pub gps_stale_after_ms: i64,
    pub uwb_stale_after_ms: i64,
}

impl Default for FusionPolicy {
    fn default() -> Self {
        Self {
            gps_stale_after_ms: 60_000,
            uwb_stale_after_ms: 2_000,
        }
    }
}

#[must_use]
pub fn relative_location(
    local: &LocationSample,
    remote: &LocationSample,
    uwb: Option<&UwbObservation>,
    now_ms: i64,
    policy: FusionPolicy,
) -> RelativeLocation {
    let gps_observed_at = local.sampled_at_ms.min(remote.sampled_at_ms);
    let gps_age = now_ms.saturating_sub(gps_observed_at).max(0);
    let gps_distance = haversine_distance_m(local, remote);
    let gps_direction = initial_bearing_radians(local, remote);
    let fresh_uwb = uwb.filter(|sample| {
        let age = now_ms.saturating_sub(sample.observed_at_ms);
        (0..=policy.uwb_stale_after_ms).contains(&age)
    });
    let distance_m = fresh_uwb
        .and_then(|sample| {
            sample
                .distance_m
                .filter(|distance| distance.is_finite() && *distance >= 0.0)
                .map(|value| SourcedMeasurement {
                    value,
                    source: RelativeSource::Uwb,
                    observed_at_ms: sample.observed_at_ms,
                })
        })
        .unwrap_or(SourcedMeasurement {
            value: gps_distance,
            source: RelativeSource::Gps,
            observed_at_ms: gps_observed_at,
        });
    let direction_radians = fresh_uwb
        .and_then(|sample| {
            sample
                .direction_radians
                .filter(|direction| direction.is_finite())
                .map(|value| SourcedMeasurement {
                    value: normalize_radians(value),
                    source: RelativeSource::Uwb,
                    observed_at_ms: sample.observed_at_ms,
                })
        })
        .unwrap_or(SourcedMeasurement {
            value: gps_direction,
            source: RelativeSource::Gps,
            observed_at_ms: gps_observed_at,
        });
    RelativeLocation {
        distance_m,
        direction_radians,
        horizontal_accuracy_m: local.horizontal_accuracy_m + remote.horizontal_accuracy_m,
        stale: gps_age > policy.gps_stale_after_ms,
        sample_age_ms: gps_age,
    }
}

#[must_use]
pub fn haversine_distance_m(from: &LocationSample, to: &LocationSample) -> f64 {
    let from_lat = from.latitude.to_radians();
    let to_lat = to.latitude.to_radians();
    let latitude_delta = (to.latitude - from.latitude).to_radians();
    let longitude_delta = (to.longitude - from.longitude).to_radians();
    let a = (latitude_delta / 2.0).sin().powi(2)
        + from_lat.cos() * to_lat.cos() * (longitude_delta / 2.0).sin().powi(2);
    2.0 * EARTH_RADIUS_M * a.sqrt().atan2((1.0 - a).sqrt())
}

#[must_use]
pub fn initial_bearing_radians(from: &LocationSample, to: &LocationSample) -> f64 {
    let from_lat = from.latitude.to_radians();
    let to_lat = to.latitude.to_radians();
    let longitude_delta = (to.longitude - from.longitude).to_radians();
    normalize_radians((longitude_delta.sin() * to_lat.cos()).atan2(
        from_lat.cos() * to_lat.sin() - from_lat.sin() * to_lat.cos() * longitude_delta.cos(),
    ))
}

fn normalize_radians(value: f64) -> f64 {
    value.rem_euclid(std::f64::consts::TAU)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn location(latitude: f64, longitude: f64) -> LocationSample {
        LocationSample {
            latitude,
            longitude,
            altitude_m: None,
            horizontal_accuracy_m: 5.0,
            speed_mps: None,
            course_degrees: None,
            sampled_at_ms: 1_000,
        }
    }

    #[test]
    fn distance_only_uwb_uses_precise_distance_and_current_gps_direction() {
        let fix = relative_location(
            &location(32.0, 118.0),
            &location(32.001, 118.002),
            Some(&UwbObservation {
                distance_m: Some(4.2),
                direction_radians: None,
                observed_at_ms: 1_900,
            }),
            2_000,
            FusionPolicy::default(),
        );
        assert_eq!(fix.distance_m.source, RelativeSource::Uwb);
        assert_eq!(fix.distance_m.value, 4.2);
        assert_eq!(fix.direction_radians.source, RelativeSource::Gps);
    }

    #[test]
    fn stale_uwb_falls_back_for_both_independent_values() {
        let fix = relative_location(
            &location(32.0, 118.0),
            &location(32.001, 118.002),
            Some(&UwbObservation {
                distance_m: Some(4.2),
                direction_radians: Some(1.0),
                observed_at_ms: 1_000,
            }),
            5_000,
            FusionPolicy::default(),
        );
        assert_eq!(fix.distance_m.source, RelativeSource::Gps);
        assert_eq!(fix.direction_radians.source, RelativeSource::Gps);
    }
}

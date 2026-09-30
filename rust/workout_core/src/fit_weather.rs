//! Swift-compatible route anchors and hourly/spatial weather interpolation.
use super::{FitDecodeError, FitDocument, haversine_meters};
use crate::weather::WeatherSample;

#[derive(Clone, Debug)]
pub struct FitWeatherStation {
    pub latitude: f64,
    pub longitude: f64,
    pub samples: Vec<WeatherSample>,
}

pub(crate) fn coordinate(document: &FitDocument, index: usize) -> Option<(f64, f64)> {
    let scale = 2_147_483_648.0 / 180.0;
    let lat = f64::from(document.read_i32(index, 0)?) / scale;
    let lon = f64::from(document.read_i32(index, 1)?) / scale;
    ((-90.0..=90.0).contains(&lat) && (-180.0..=180.0).contains(&lon)).then_some((lat, lon))
}

pub fn fit_weather_anchors(data: &[u8]) -> Result<Vec<(f64, f64)>, FitDecodeError> {
    let doc = FitDocument::parse(data)?;
    let mut records = doc
        .messages()
        .iter()
        .enumerate()
        .filter(|(_, m)| m.global_number() == 20)
        .filter_map(|(i, _)| Some((doc.read_u32(i, 253)?, coordinate(&doc, i)?)))
        .collect::<Vec<_>>();
    records.sort_by_key(|r| r.0);
    let Some(&(first_time, first)) = records.first() else {
        return Ok(vec![]);
    };
    let mut anchors = vec![first];
    let mut previous = first;
    let mut last_time = first_time;
    let mut traveled = 0.0;
    for &(time, point) in records.iter().skip(1) {
        traveled += haversine_meters(previous.0, previous.1, point.0, point.1);
        if traveled >= 5_000.0 || time.saturating_sub(last_time) >= 600 {
            append_anchor(&mut anchors, point);
            traveled = 0.0;
            last_time = time;
        }
        previous = point;
    }
    append_anchor(&mut anchors, previous);
    if anchors.len() > 12 {
        let last = anchors.len() - 1;
        anchors = (0..12).map(|i| anchors[i * last / 11]).collect();
    }
    Ok(anchors)
}

fn append_anchor(anchors: &mut Vec<(f64, f64)>, point: (f64, f64)) {
    if anchors
        .last()
        .is_none_or(|last| haversine_meters(last.0, last.1, point.0, point.1) >= 50.0)
    {
        anchors.push(point);
    }
}

fn blend(a: &WeatherSample, b: &WeatherSample, weight: f64, time: i64) -> WeatherSample {
    let lerp = |x: f64, y: f64| x + (y - x) * weight;
    WeatherSample {
        time_seconds: time,
        temperature_c: lerp(a.temperature_c, b.temperature_c),
        relative_humidity_percent: lerp(a.relative_humidity_percent, b.relative_humidity_percent),
        pressure_msl_hpa: lerp(a.pressure_msl_hpa, b.pressure_msl_hpa),
        wind_speed_mps: lerp(a.wind_speed_mps, b.wind_speed_mps),
        wind_from_degrees: (a.wind_from_degrees
            + ((b.wind_from_degrees - a.wind_from_degrees + 180.0).rem_euclid(360.0) - 180.0)
                * weight)
            .rem_euclid(360.0),
    }
}

pub(crate) fn interpolate(time: i64, samples: &[WeatherSample]) -> Option<WeatherSample> {
    let first = samples.first()?;
    if time <= first.time_seconds {
        return Some(first.clone());
    }
    let last = samples.last()?;
    if time >= last.time_seconds {
        return Some(last.clone());
    }
    let next = samples.partition_point(|sample| sample.time_seconds < time);
    let a = &samples[next - 1];
    let b = &samples[next];
    let span = b.time_seconds - a.time_seconds;
    if span <= 0 {
        return Some(a.clone());
    }
    Some(blend(
        a,
        b,
        (time - a.time_seconds) as f64 / span as f64,
        time,
    ))
}

pub(crate) fn weather_at(
    time: i64,
    point: Option<(f64, f64)>,
    stations: &[FitWeatherStation],
) -> Option<WeatherSample> {
    let first = stations.first()?;
    let Some((lat, lon)) = point else {
        return interpolate(time, &first.samples);
    };
    let mut ranked = stations
        .iter()
        .map(|station| {
            (
                station,
                haversine_meters(lat, lon, station.latitude, station.longitude),
            )
        })
        .collect::<Vec<_>>();
    ranked.sort_by(|a, b| a.1.total_cmp(&b.1));
    let nearest = ranked[0];
    let sample = interpolate(time, &nearest.0.samples);
    let Some(second) = ranked.get(1) else {
        return sample;
    };
    let Some(sample) = sample else {
        return interpolate(time, &second.0.samples);
    };
    if nearest.1 + second.1 <= 1.0 || second.1 >= 25_000.0 {
        return Some(sample);
    }
    Some(match interpolate(time, &second.0.samples) {
        Some(other) => blend(&sample, &other, nearest.1 / (nearest.1 + second.1), time),
        None => sample,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    fn sample(time: i64, direction: f64) -> WeatherSample {
        WeatherSample {
            time_seconds: time,
            temperature_c: 20.0,
            relative_humidity_percent: 50.0,
            pressure_msl_hpa: 1013.25,
            wind_speed_mps: 5.0,
            wind_from_degrees: direction,
        }
    }
    #[test]
    fn interpolates_wind_across_north_and_clamps_time() {
        let samples = vec![sample(100, 350.0), sample(200, 10.0)];
        assert_eq!(interpolate(150, &samples).unwrap().wind_from_degrees, 0.0);
        assert_eq!(interpolate(0, &samples).unwrap().wind_from_degrees, 350.0);
        assert_eq!(interpolate(500, &samples).unwrap().wind_from_degrees, 10.0);
        assert!(interpolate(100, &[]).is_none());
    }
    #[test]
    fn spatial_blending_uses_nearest_stations() {
        let stations = vec![
            FitWeatherStation {
                latitude: 0.0,
                longitude: 0.0,
                samples: vec![sample(100, 350.0)],
            },
            FitWeatherStation {
                latitude: 0.0,
                longitude: 0.02,
                samples: vec![sample(100, 10.0)],
            },
        ];
        let result = weather_at(100, Some((0.0, 0.01)), &stations).unwrap();
        assert!(result.wind_from_degrees.abs() < 0.001);
        assert_eq!(
            weather_at(100, None, &stations).unwrap().wind_from_degrees,
            350.0
        );
    }
}

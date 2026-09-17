// weather.js — 天气应用与小组件共用的数据与换算逻辑
// 数据源: Open-Meteo (预报 + 空气质量), 免费、无需密钥、支持中文地名检索。
.pragma library

var DEFAULT_CITY = { name: "太原", lat: 37.8706, lon: 112.5489, admin: "山西" }
var DEFAULT_CONFIG = { cities: [DEFAULT_CITY], current: 0, unit: "c", refresh: 3600 }
var COMMON_CITIES = [
    { name: "北京", lat: 39.9042, lon: 116.4074, admin: "北京" },
    { name: "上海", lat: 31.2304, lon: 121.4737, admin: "上海" },
    { name: "广州", lat: 23.1291, lon: 113.2644, admin: "广东" },
    { name: "深圳", lat: 22.5431, lon: 114.0579, admin: "广东" },
    { name: "杭州", lat: 30.2741, lon: 120.1551, admin: "浙江" },
    { name: "成都", lat: 30.5728, lon: 104.0668, admin: "四川" },
    { name: "西安", lat: 34.3416, lon: 108.9398, admin: "陕西" },
    { name: "太原", lat: 37.8706, lon: 112.5489, admin: "山西" }
]

var CODES = {
    0: "晴", 1: "晴间多云", 2: "多云", 3: "阴",
    45: "雾", 48: "雾凇",
    51: "毛毛雨", 53: "小雨", 55: "中雨", 56: "冻毛毛雨", 57: "冻雨",
    61: "小雨", 63: "中雨", 65: "大雨", 66: "冻雨", 67: "冻雨",
    71: "小雪", 73: "中雪", 75: "大雪", 77: "米雪",
    80: "阵雨", 81: "阵雨", 82: "强阵雨", 85: "阵雪", 86: "强阵雪",
    95: "雷阵雨", 96: "雷阵雨伴冰雹", 99: "雷阵雨伴冰雹"
}

function codeText(c) { return CODES[c] !== undefined ? CODES[c] : "未知" }

// 天气代码 → 图标文件名 (assets/ 下); day=false 用夜间图标
function codeIcon(c, day) {
    if (day === undefined) day = true
    if (c === 0) return day ? "w-sun" : "w-moon"
    if (c === 1) return day ? "w-partly" : "w-partly-night"   // 晴间多云 = 太阳加云
    if (c === 2) return "w-cloud"                              // 多云 = 只有云
    if (c === 3) return "w-cloud"
    if (c === 45 || c === 48) return "w-fog"
    if (c >= 95) return "w-thunder"
    if (c === 51 || c === 53 || c === 56 || c === 57) return "w-drizzle"
    if ((c >= 61 && c <= 67) || (c >= 80 && c <= 82)) return "w-rain"
    if ((c >= 71 && c <= 77) || c === 85 || c === 86) return "w-snow"
    return "w-cloud"
}

function isRainy(c) { return (c >= 51 && c <= 67) || (c >= 80 && c <= 82) || c >= 95 }
function isSnowy(c) { return (c >= 71 && c <= 77) || c === 85 || c === 86 }

// ─── 风 ───
function windDir(deg) {
    var names = ["北风", "东北风", "东风", "东南风", "南风", "西南风", "西风", "西北风"]
    return names[Math.round((deg % 360) / 45) % 8]
}
// 蒲福风级 (km/h)
function windLevel(kmh) {
    var b = [1, 6, 12, 20, 29, 39, 50, 62, 75, 89, 103, 118]
    for (var i = 0; i < b.length; i++) if (kmh < b[i]) return i
    return 12
}

// ─── 空气质量 (用 US AQI, 按国标分档命名) ───
function aqiText(aqi) {
    if (aqi === undefined || aqi === null) return ""
    if (aqi <= 50) return "优"
    if (aqi <= 100) return "良"
    if (aqi <= 150) return "轻度污染"
    if (aqi <= 200) return "中度污染"
    if (aqi <= 300) return "重度污染"
    return "严重污染"
}

function uvText(uv) {
    if (uv === undefined || uv === null) return ""
    if (uv < 3) return "最弱"
    if (uv < 6) return "弱"
    if (uv < 8) return "中等"
    if (uv < 11) return "强"
    return "很强"
}

// ─── 温度单位 ───
function toUnit(c, unit) { return unit === "f" ? Math.round(c * 9 / 5 + 32) : Math.round(c) }
function unitSign(unit) { return unit === "f" ? "°F" : "°C" }

function advice(d) {
    if (!d) return ""
    if (d.code >= 95) return "有雷雨，尽量待在室内。"
    if (isSnowy(d.code)) return "在下雪，路面湿滑注意保暖。"
    if (isRainy(d.code)) return "有雨，出门记得带伞。"
    if (d.code === 45 || d.code === 48) return "有雾，出行注意能见度。"
    if (d.aqi > 150) return "空气不太好，减少户外活动。"
    if (d.temp >= 32) return "今天很热，注意补水防晒。"
    if (d.temp <= 0) return "今天很冷，出门多穿一件。"
    if (d.code <= 1) return "今天天气晴朗，适合出门走走。"
    return "今天多云，适合安静地读一本书。"
}

// ─── 生活指数 (依据当天的温度/降水/风/紫外线/空气) ───
function indices(d) {
    if (!d) return []
    var t = d.feels !== undefined ? d.feels : d.temp
    var rain = d.precipToday > 0.2 || isRainy(d.code)
    var wind = windLevel(d.wind)
    var out = []

    var wear = t >= 30 ? ["炎热", "短袖短裤"] : t >= 24 ? ["舒适", "薄长袖"]
             : t >= 16 ? ["温和", "长袖外套"] : t >= 8 ? ["较凉", "夹克毛衣"]
             : t >= 0 ? ["较冷", "厚外套"] : ["寒冷", "羽绒服"]
    out.push({ icon: "i-shirt", name: "穿衣", level: wear[0], detail: wear[1] })

    out.push({ icon: "i-car", name: "出行", level: rain ? "较不宜" : wind >= 6 ? "注意风大" : "适宜",
               detail: rain ? "路面湿滑" : "路况良好" })

    out.push({ icon: "i-carwash", name: "洗车", level: d.precipNext48 > 1 ? "不宜" : "适宜",
               detail: d.precipNext48 > 1 ? "近两天有雨" : "两天内无雨" })

    out.push({ icon: "i-run", name: "运动", level: (rain || d.aqi > 150 || t > 33 || t < -5) ? "不宜" : (wind >= 6 || d.aqi > 100) ? "较适宜" : "适宜",
               detail: rain ? "改为室内" : d.aqi > 100 ? "空气一般" : "适合户外" })

    var swing = d.hi - d.lo
    out.push({ icon: "i-health", name: "感冒", level: (swing >= 10 || t < 5) ? "易发" : swing >= 7 ? "较易发" : "少发",
               detail: swing >= 7 ? "昼夜温差大" : "温差不大" })

    out.push({ icon: "i-uv", name: "紫外线", level: uvText(d.uv), detail: d.uv >= 6 ? "注意防晒" : "影响较小" })

    out.push({ icon: "i-fish", name: "钓鱼", level: (rain || wind >= 5) ? "不宜" : (t < 5 || t > 32) ? "较适宜" : "适宜",
               detail: wind >= 5 ? "风力偏大" : "水面平稳" })

    out.push({ icon: "i-travel", name: "旅游", level: (rain || wind >= 6) ? "较不宜" : (d.code <= 2 && t >= 10 && t <= 30) ? "适宜" : "较适宜",
               detail: d.code <= 2 ? "风景清晰" : "视野一般" })

    out.push({ icon: "i-dry", name: "晾晒", level: rain ? "不宜" : (d.humidity > 80 ? "较不宜" : d.code <= 1 ? "非常适宜" : "适宜"),
               detail: rain ? "有降水" : d.humidity > 80 ? "湿度偏高" : "干爽有风" })
    return out
}

// ─── 请求 ───
function forecastUrl(lat, lon) {
    return "https://api.open-meteo.com/v1/forecast?latitude=" + lat + "&longitude=" + lon
        + "&current=temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m,wind_direction_10m,is_day,precipitation"
        + "&hourly=temperature_2m,weather_code,is_day,precipitation_probability,visibility,uv_index"
        + "&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_sum,uv_index_max,sunrise,sunset"
        + "&timezone=auto&forecast_days=7"
}
function airUrl(lat, lon) {
    return "https://air-quality-api.open-meteo.com/v1/air-quality?latitude=" + lat + "&longitude=" + lon
        + "&current=us_aqi,pm2_5,pm10&timezone=auto"
}
function geocodeUrl(name) {
    return "https://geocoding-api.open-meteo.com/v1/search?name=" + encodeURIComponent(name)
        + "&count=8&language=zh&format=json"
}

function cityKey(city) { return city.lat.toFixed(2) + "," + city.lon.toFixed(2) }

// 当前小时在 hourly 数组里的下标 (Open-Meteo 的 time 是当地时间字符串)
function hourIndex(r) {
    var t = (r.current && r.current.time) ? r.current.time.substring(0, 13) : ""
    var arr = (r.hourly && r.hourly.time) || []
    for (var i = 0; i < arr.length; i++) if (arr[i].substring(0, 13) === t) return i
    return 0
}

// 把两个接口的返回整理成界面直接可用的结构
function parse(r, air, city) {
    var cur = r.current || {}, d = r.daily || {}, h = r.hourly || {}
    var hi0 = hourIndex(r)
    var hours = []
    for (var i = hi0; i < Math.min(hi0 + 24, (h.time || []).length); i++) {
        hours.push({ time: h.time[i].substring(11, 16), hour: h.time[i].substring(11, 13),
                     code: h.weather_code[i], day: h.is_day[i] === 1,
                     temp: Math.round(h.temperature_2m[i]),
                     pop: h.precipitation_probability ? h.precipitation_probability[i] : 0 })
    }
    var days = []
    for (var j = 0; j < (d.time || []).length; j++)
        days.push({ date: d.time[j], code: d.weather_code[j],
                    hi: Math.round(d.temperature_2m_max[j]), lo: Math.round(d.temperature_2m_min[j]),
                    precip: d.precipitation_sum ? d.precipitation_sum[j] : 0,
                    uv: d.uv_index_max ? d.uv_index_max[j] : 0,
                    sunrise: d.sunrise ? d.sunrise[j].substring(11, 16) : "",
                    sunset: d.sunset ? d.sunset[j].substring(11, 16) : "" })
    var acur = (air && air.current) || {}
    var next48 = 0
    for (var k = 0; k < Math.min(2, days.length); k++) next48 += days[k].precip || 0

    var out = {
        city: city.name, lat: city.lat, lon: city.lon,
        temp: Math.round(cur.temperature_2m),
        feels: Math.round(cur.apparent_temperature),
        humidity: Math.round(cur.relative_humidity_2m),
        code: cur.weather_code, day: cur.is_day === 1,
        wind: Math.round(cur.wind_speed_10m || 0),
        windDeg: cur.wind_direction_10m || 0,
        hi: days.length ? days[0].hi : Math.round(cur.temperature_2m),
        lo: days.length ? days[0].lo : Math.round(cur.temperature_2m),
        uv: (h.uv_index && h.uv_index[hi0] !== undefined) ? Math.round(h.uv_index[hi0] * 10) / 10 : (days.length ? days[0].uv : 0),
        visibility: (h.visibility && h.visibility[hi0] !== undefined) ? Math.round(h.visibility[hi0] / 1000) : null,
        aqi: acur.us_aqi !== undefined ? Math.round(acur.us_aqi) : null,
        pm25: acur.pm2_5 !== undefined ? Math.round(acur.pm2_5) : null,
        sunrise: days.length ? days[0].sunrise : "", sunset: days.length ? days[0].sunset : "",
        precipToday: days.length ? days[0].precip : 0, precipNext48: next48,
        hours: hours, days: days,
        date: (cur.time || "").substring(0, 10),
        at: Date.now()
    }
    out.text = codeText(out.code)
    out.advice = advice(out)
    return out
}

// 拉一个城市的天气; cb(data | null, errText)。空气质量失败不影响主数据。
function fetchCity(space, city, cb) {
    space.request("GET", forecastUrl(city.lat, city.lon), null, function(st, r) {
        if (st !== 200 || !r || !r.current) { cb(null, st === 0 ? "网络不可达" : ("天气服务返回 " + st)); return }
        space.request("GET", airUrl(city.lat, city.lon), null, function(st2, air) {
            cb(parse(r, (st2 === 200 ? air : null), city), "")
        })
    })
}

// 城市检索: cb([{name,lat,lon,admin,country}], errText)
function geocode(space, name, cb) {
    space.request("GET", geocodeUrl(name), null, function(st, r) {
        if (st !== 200 || !r) { cb([], st === 0 ? "网络不可达" : ("地理服务返回 " + st)); return }
        var out = []
        var res = r.results || []
        for (var i = 0; i < res.length; i++)
            out.push({ name: res[i].name, lat: res[i].latitude, lon: res[i].longitude,
                       admin: res[i].admin1 || "", country: res[i].country || "" })
        cb(out, out.length ? "" : "没找到这个城市")
    })
}

// 首页插画: 按季节 + 天气挑图, 放在 assets/scenes/ 下。
// 命名: <季节>-<天气>[-night].jpg, 季节 spring|summer|autumn|winter,
// 天气 clear|cloudy|rain|snow|storm|fog; 夜间只有 clear 与 cloudy 有 -night。
// 缺图时按 sceneChain() 逐级回落, 最后才用自带的矢量插画。
function sceneKind(code) {
    if (code === 0 || code === 1) return "clear"
    if (code === 2 || code === 3) return "cloudy"
    if (code === 45 || code === 48) return "fog"
    if (code >= 95) return "storm"
    if (isSnowy(code)) return "snow"
    return "rain"
}
function season(d) {
    var m = d.getMonth() + 1
    if (m >= 3 && m <= 5) return "spring"
    if (m >= 6 && m <= 8) return "summer"
    if (m >= 9 && m <= 11) return "autumn"
    return "winter"
}
function sceneFile(wx, now, allowNight) {
    if (!wx) return "scene.svg"
    var kind = sceneKind(wx.code)
    var night = (allowNight && !wx.day && (kind === "clear" || kind === "cloudy")) ? "-night" : ""
    return "scenes/" + season(now) + "-" + kind + night + ".jpg"
}

// 同一种天气在别的季节的备选顺序。某些组合现实中罕见 (如夏天下雪),
// 素材可以不画; 这时优先借用气质最接近的季节, 而不是直接掉回矢量插画。
var SEASON_ALT = {
    spring: ["autumn", "summer", "winter"],
    summer: ["spring", "autumn", "winter"],
    autumn: ["spring", "winter", "summer"],
    winter: ["autumn", "spring", "summer"]
}

// 返回按优先级排好的候选图列表: 夜间图 → 同款白天图 → 邻近季节同款 → 矢量插画。
function sceneChain(wx, now) {
    if (!wx) return ["scene.svg"]
    var kind = sceneKind(wx.code)
    var here = season(now)
    var night = (!wx.day && (kind === "clear" || kind === "cloudy")) ? "-night" : ""
    var out = []
    if (night) out.push("scenes/" + here + "-" + kind + night + ".jpg")
    out.push("scenes/" + here + "-" + kind + ".jpg")
    var alt = SEASON_ALT[here] || []
    for (var i = 0; i < alt.length; ++i)
        out.push("scenes/" + alt[i] + "-" + kind + ".jpg")
    out.push("scene.svg")
    return out
}

function weekday(dateStr) {
    var d = new Date(dateStr + "T00:00:00")
    return ["周日", "周一", "周二", "周三", "周四", "周五", "周六"][d.getDay()]
}
function mmdd(dateStr) { return dateStr.substring(5).replace("-", "/") }

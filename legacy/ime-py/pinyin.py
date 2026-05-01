# ime/pinyin.py
import json
from pathlib import Path
from pypinyin import lazy_pinyin, Style

_DICT_PATH = Path(__file__).parent / "dict" / "chars.json"

_HIGH_FREQ: dict[str, list[str]] = {
    "ni":    ["你", "泥", "呢", "逆", "匿"],
    "hao":   ["好", "号", "豪", "毫", "浩"],
    "nihao": ["你好"],
    "wo":    ["我", "窝", "握", "卧", "涡"],
    "shi":   ["是", "时", "事", "使", "式"],
    "de":    ["的", "得", "地", "德", "底"],
    "zai":   ["在", "再", "载", "哉", "栽"],
    "he":    ["和", "河", "合", "何", "喝"],
    "ta":    ["他", "她", "它", "踏", "塌"],
    "men":   ["们", "门", "闷", "焖"],
    "a":     ["啊", "阿", "哦", "哈"],
    "ma":    ["吗", "妈", "马", "麻", "骂"],
    "guo":   ["国", "过", "果", "锅", "裹"],
    "zhong": ["中", "种", "重", "众", "钟"],
    "wen":   ["文", "问", "闻", "稳", "蚊"],
    "xie":   ["谢", "些", "写", "斜", "鞋"],
    "zhen":  ["真", "阵", "针", "珍", "枕"],
    "lai":   ["来", "赖", "莱", "睐"],
    "qu":    ["去", "区", "取", "趣", "曲"],
    "kan":   ["看", "刊", "堪", "砍"],
    "ting":  ["听", "停", "庭", "廷"],
    "shuo":  ["说", "朔", "硕"],
    "dui":   ["对", "队", "堆", "兑"],
    "you":   ["有", "又", "由", "友", "右"],
    "mei":   ["没", "美", "每", "妹", "媒"],
    "ren":   ["人", "任", "忍", "认", "仁"],
}

MAX_CANDIDATES = 5


class PinyinEngine:
    def __init__(self, dict_path: Path = _DICT_PATH):
        self.buffer: str = ""
        self._char_dict: dict[str, list[str]] = {}
        if dict_path.exists():
            with open(dict_path, encoding="utf-8") as f:
                self._char_dict = json.load(f)

    def append(self, char: str) -> None:
        """追加一个字母到拼音缓冲区"""
        if char.isalpha():
            self.buffer += char.lower()

    def backspace(self) -> None:
        """删除缓冲区最后一个字符"""
        self.buffer = self.buffer[:-1]

    def clear(self) -> None:
        """清空缓冲区"""
        self.buffer = ""

    @property
    def candidates(self) -> list[str]:
        return self.get_candidates(self.buffer)

    def get_candidates(self, pinyin: str) -> list[str]:
        """给定拼音字符串，返回候选字/词列表（最多 MAX_CANDIDATES 个）"""
        if not pinyin or not pinyin.isalpha():
            return []
        if pinyin in _HIGH_FREQ:
            return _HIGH_FREQ[pinyin][:MAX_CANDIDATES]
        return self._char_dict.get(pinyin, [])[:MAX_CANDIDATES]

"""Build data/<character>.json from the Ys Origin apworld's own logic (github.com/4rtefakt/ys-origin-archipelago).

    python .dev/build_data.py <Archipelago checkout with ys_origin.apworld in custom_worlds/>

For each character it generates a vanilla-layout world (chests and events only, no warp locks, no progressive
gear), takes the region graph and rules the apworld exports for trackers, and adds each location's vanilla item.
It then checks that the vanilla layout is fully reachable under that logic.
"""
import collections, importlib, json, os, sys, warnings

os.environ["SKIP_REQUIREMENTS_UPDATE"] = "1"
warnings.filterwarnings("ignore")
sys.stdin = open(os.devnull)
OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "data")
ap = os.path.abspath(sys.argv[1])
os.chdir(ap)
sys.path.insert(0, ap)
from test.general import setup_multiworld, gen_steps      # noqa: E402
from worlds.AutoWorld import AutoWorldRegister            # noqa: E402

world = AutoWorldRegister.world_types["Ys Origin"]
dt = importlib.import_module(world.__module__ + ".data_tables")
KEEP = {"Cleria Ore", "Emerald", "Ruby", "Topaz"}          # their chests do more than store an item: left alone


def names_in(rule, out):
    if isinstance(rule, list):
        if rule[0] == "has":
            out.add(rule[1])
        else:
            for c in rule[1:]:
                names_in(c, out)


def sweep(data, placed):
    """Regions and locations reachable from the start with the items found on the way."""
    have = collections.Counter(data["start"])
    reach, got = {0}, set()

    def ok(r):
        if r is True or r is False:
            return r
        if r[0] == "has":
            return have[r[1]] >= r[2]
        if r[0] == "reach":
            return r[1] in reach
        return (all if r[0] == "all" else any)(ok(c) for c in r[1:])
    grew = True
    while grew:
        grew = False
        for a, b, r in data["entrances"]:
            if a in reach and b not in reach and ok(r):
                reach.add(b)
                grew = True
        for i, loc in enumerate(data["locs"]):
            if i not in got and loc["region"] in reach and ok(loc["rule"]):
                got.add(i)
                grew = True
                if placed[i]:
                    have[placed[i]] += 1
    return reach, got


os.makedirs(OUT, exist_ok=True)
for ch, name in ((0, "yunica"), (1, "hugo"), (2, "toal")):
    opts = {"character": ch, "statue_checks": 0, "blessing_checks": 0, "boss_checks": 0, "floor_checks": 0, "room_checks": 0,
            "statue_warp_locks": 0, "random_start": 0, "progressive_armor": 0, "weapon_requirements": 0, "level_scaling": 0,
            "trap_count": 0}
    mw = setup_multiworld(world, gen_steps, seed=1, options=opts)
    w = mw.worlds[1]
    logic = w.fill_slot_data()["logic"]
    by_id = {v: k for k, v in w.location_name_to_id.items()}
    locs, used = [], set()
    for lid, (region, rule) in sorted(logic["locations"].items(), key=lambda kv: int(kv[0])):
        lname = by_id[int(lid)]
        meta = dt.LOC_META[lname]
        item = dt.location_vanilla_item(lname, name) or None
        written = dt.location_written_item(lname, name) or None
        chest = meta["id"] if meta["type"] == "chest" else None
        iid = dt.item_index.get(written or item or "", -1)
        if item and dt.progressive_skill_for(item):        # the rules name a skill by its chain
            item = dt.progressive_skill_for(item)
        shuffle = bool(chest and item and item not in KEEP and 0 <= iid < 0x80)
        locs.append(dict(name=lname, region=region, rule=rule, item=item, id=iid if item else -1, chest=chest, shuffle=shuffle))
        names_in(rule, used)
    for a, b, r in logic["entrances"]:
        names_in(r, used)
    data = dict(character=name, regions=logic["regions"], entrances=logic["entrances"], locs=locs,
                start=[i.name for i in mw.precollected_items[1]],
                goal=logic["regions"].index(dt.scene_region("S_6097")))
    have = {l["item"] for l in locs if l["item"]} | set(data["start"])
    missing = sorted(used - have)
    reach, got = sweep(data, [l["item"] for l in locs])
    n = sum(l["shuffle"] for l in locs)
    print(f"{name}: {len(locs)} locations, {n} shuffled chests, {len(data['regions'])} regions; "
          f"vanilla layout reaches {len(got)}/{len(locs)} locations, goal region {'yes' if data['goal'] in reach else 'NO'}; "
          f"rule items with no source: {missing or 'none'}")
    with open(os.path.join(OUT, name + ".json"), "w", encoding="utf-8") as f:
        json.dump(data, f, separators=(",", ":"))

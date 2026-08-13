const sourceNodeIds = [
  "bpmkbvvo", "bpmkbvvp", "bpmkbvvq", "bpmkbvvr", "bpmkbvvs", "bpmkbvvt", "bpmkbvvu", "bpmkbvvv",
  "bpmkbvvw", "bpmkbvvx", "bpmkbvvy", "bpmkbvvz", "bpmkbvwa", "bpmkbvwb", "bpmkbvwc", "bpmkbvwd",
  "bpmkbvwe", "bpmkbvwf", "bpmkbvwg", "bpmkbvwh", "bpmkbvwi", "bpmkbvwj", "bpmkbvwk", "bpmkbvwl",
  "bpmkbvwm", "bpmkbvwn", "bpmkbvwo", "bpmkbvwp", "bpmkbvwq", "bpmkbvwr", "bpmkbvws", "bpmkbvwt",
  "bpmkbvwu", "bpmkbvwv", "bpmkbvww", "bpmkbvwx", "bpmkbvwy", "bpmkbvwz", "bpmkbvxa", "bpmkbvxb",
  "bpmkbvxc", "bpmkbvxd", "bpmkbvxe", "bpmkbvxf", "bpmkbvxg", "bpmkbvxh", "bpmkbvxi", "bpmkbvxj",
];

const textNodeIds = new Set([
  "bpmkbvvq", "bpmkbvvs", "bpmkbvvt", "bpmkbvvu", "bpmkbvvv", "bpmkbvvy", "bpmkbvvz", "bpmkbvwa",
  "bpmkbvwc", "bpmkbvwd", "bpmkbvwi", "bpmkbvwj", "bpmkbvwl", "bpmkbvwq", "bpmkbvwr", "bpmkbvws",
  "bpmkbvww", "bpmkbvwx", "bpmkbvxa", "bpmkbvxb", "bpmkbvxe", "bpmkbvxf", "bpmkbvxh", "bpmkbvxi", "bpmkbvxj",
]);

const viewports = [390, 483, 484, 485, 615, 616, 617, 637, 638, 639, 767, 768, 769, 775, 776, 777, 783, 784, 785, 919, 920, 921, 1151, 1152, 1153, 1440];
const viewportHeight = 900;

function browserInspectScript({ selectorKind, ids }) {
  const properties = [
    "display", "visibility", "position", "flexDirection", "flexWrap", "rowGap", "columnGap",
    "justifyContent", "alignItems", "gridTemplateColumns", "overflow", "fontFamily", "fontSize",
    "fontWeight", "lineHeight", "color", "background", "border", "borderRadius", "transform", "zIndex",
  ];
  const elementForId = (id) => {
    const selector = selectorKind === "class" ? `.${id}` : `[data-exporter-id="${id}"]`;
    const matches = document.querySelectorAll(selector);
    return matches.length === 1 ? matches[0] : null;
  };
  const elements = {};
  for (const id of ids) {
    const element = elementForId(id);
    if (!element) {
      elements[id] = { absent: true };
      continue;
    }
    const rect = element.getBoundingClientRect();
    const computedStyle = getComputedStyle(element);
    elements[id] = {
      tag: element.tagName.toLowerCase(),
      box: { x: rect.x, y: rect.y, width: rect.width, height: rect.height },
      ...Object.fromEntries(properties.map((property) => [property, computedStyle[property]])),
    };
  }
  return {
    clientWidth: document.documentElement.clientWidth,
    scrollWidth: document.documentElement.scrollWidth,
    scrollHeight: document.documentElement.scrollHeight,
    interAvailable: document.fonts.check("16px Inter"),
    elements,
  };
}

module.exports = { sourceNodeIds, textNodeIds, viewports, viewportHeight, browserInspectScript };

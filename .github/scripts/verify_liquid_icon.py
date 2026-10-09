"""Check compiled icon appearances, rather than just their presence in Assets.car."""
import argparse
import json
from pathlib import Path


def verify(catalog):
    colors = {a['Name']: a for a in catalog if a.get('AssetType') == 'Color'}
    gradients = {a['Name']: a for a in catalog if a.get('AssetType') == 'Named Gradient'}

    def rgba(color):
        values = color['Color components']
        return values if len(values) == 4 else [values[0]] * 3 + [values[1]]

    def fill_colors(layer):
        name = layer.get('LayerGradientColorName', layer.get('Name'))
        if name in colors:
            return [rgba(colors[name])]
        assert name in gradients, f'Unresolved compiled fill: {layer}'
        return [rgba(colors[c]) for c in gradients[name]['Gradient Colors']]

    def solid(layer, value):
        actual = fill_colors(layer)
        # actool quantizes serialized sRGB components (122/255 becomes 0.478).
        # Compare the intended 8-bit color; also require identical gray fills below.
        assert actual and all(len(c) == 4 and all(round(x * 255) == round(value * 255) for x in c[:3]) and c[3] == 1 for c in actual), actual
        return actual

    report = {}
    groups = {}
    for appearance, symbol_color in [('UIAppearanceLight', 0), ('UIAppearanceDark', 1)]:
        matches = [a for a in catalog if a.get('AssetType') == 'IconGroup' and a.get('Appearance') == appearance and a.get('Name', '').startswith('zen/')]
        assert len(matches) == 1, f'{appearance}: expected one logo group, found {len(matches)}'
        group = matches[0]
        layers = {a['Name'].rsplit('/', 1)[-1]: a for a in group['Layers']}
        assert set(layers) == {'zen-symbol', 'zen-gray'}, f'{appearance}: wrong artwork layers: {list(layers)}'
        for layer in layers.values():
            assert layer['AssetType'] == 'Vector' and layer['LayerHasLightingEffects']
            assert layer['LayerPosition'] == '0,0' and layer['LayerSize'] == '1024,1024'
            assert layer['LayerOpacity'] == 1
        symbol = solid(layers['zen-symbol'], symbol_color)
        gray = solid(layers['zen-gray'], 122 / 255)
        stacks = [a for a in catalog if a.get('AssetType') == 'IconImageStack' and a.get('Appearance') == appearance and a.get('Name') == 'zen']
        assert len(stacks) == 1
        stack = stacks[0]
        assert stack['CanvasWidth'] == stack['CanvasHeight'] == 1024
        background = next(a for a in stack['Layers'] if a.get('AssetType') != 'IconGroup')
        background_colors = fill_colors(background)
        assert len(background_colors) >= 2 and len({tuple(c) for c in background_colors}) > 1, f'{appearance}: flat background: {background}'
        lighting = next(a for a in stack['Layers'] if a.get('AssetType') == 'IconGroup' and a.get('Appearance') == appearance)
        assert lighting['LayerHasSpecular'] and lighting['LayerGathersSpecularByElement']
        assert abs(lighting['LayerShadowOpacity'] - 0.35) < 0.0001 and lighting['LayerShadowStyle'] == 3
        report[appearance] = {'symbol': symbol, 'gray': gray, 'background': background_colors, 'specular': True, 'shadowOpacity': lighting['LayerShadowOpacity']}
        groups[appearance] = layers
    for name in ('zen-symbol', 'zen-gray'):
        assert groups['UIAppearanceLight'][name]['SHA1Digest'] == groups['UIAppearanceDark'][name]['SHA1Digest'], f'Artwork geometry changed with appearance: {name}'
    assert report['UIAppearanceLight']['gray'] == report['UIAppearanceDark']['gray']
    return {'state': 'PASS', 'appearances': report}


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('catalog', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    result = json.dumps(verify(json.loads(args.catalog.read_text())), indent=2) + '\n'
    if args.output:
        args.output.write_text(result)
    print(result)

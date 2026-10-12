"""
Interview-map upgrades for QGIS 3.x.
AUTOMATED WORKSPACE SETUP AND FLIGHT TRACKING SIMULATION
"""
import os
from qgis.core import (
    QgsProject, QgsApplication, QgsDataSourceUri, QgsVectorLayer, QgsRasterLayer,
    QgsProviderRegistry, QgsLayerTree,
    QgsCategorizedSymbolRenderer, QgsRendererCategory, QgsSingleSymbolRenderer,
    QgsFillSymbol, QgsLineSymbol, QgsMarkerSymbol, QgsSvgMarkerSymbolLayer,
    QgsSymbolLayer, QgsProperty,
    QgsPalLayerSettings, QgsTextFormat, QgsTextBufferSettings, QgsVectorLayerSimpleLabeling,
    QgsCoordinateReferenceSystem, QgsCoordinateTransform,
    QgsPrintLayout, QgsLayoutItemMap, QgsLayoutItemLabel, QgsLayoutItemLegend,
    QgsLayoutItemScaleBar, QgsLayoutItemPicture, QgsLayoutPoint, QgsLayoutSize, QgsUnitTypes,
)
from qgis.PyQt.QtGui import QColor, QFont
from qgis.PyQt.QtCore import QTimer
from qgis.utils import iface

# =============================== CONFIG =====================================
HOST, PORT, DBNAME = "localhost", "5432", "faa_db"
USER, PASSWORD = "postgres", ""        
AUTHCFG = ""                           
SCHEMA = "dcaviation"

CLUTTER_LAYERS = {"Airports": 3_000_000, "Regional Airports": 6_000_000}
HIDE_BASEMAPS = ["Google Satellite", "Basemap", "VersaTiles Colorful"]
REMOVE_HIDDEN = False
GROUP_ANALYSIS = ["Top 3 Diversion Airports", "Route Reference Point", "Simulated Active Flight Route",
                  "Filtered Regional Airports", "Regional Airports",
                  "150 NM Regional Buffer (Washington D.C)"]
GROUP_REFERENCE = ["Airports", "Airport Codes", "Airport Runways", "Streets"]
GROUP_BASEMAPS = ["ESRI World Topo"]

USE_DC_EQUIDISTANT_CRS = True          
ADD_WEATHER = True                     
WEATHER_VISIBLE = False                
MAKE_LAYOUT = True
LAYOUT_TITLE = "Diversion Airport Analysis: 150 NM Washington, D.C. Region"
DATA_SOURCE_NOTE = ("Simulated flight. Airport and runway data from PostGIS database faa_db. "
                    "Illustrative only; not for navigation.")
PLANE_ANGLE_OFFSET = 0                 
# ============================================================================

project = QgsProject.instance()
root = project.layerTreeRoot()
LIVE_LAYERS = []

def base_uri():
    uri = QgsDataSourceUri()
    if AUTHCFG:
        uri.setConnection(HOST, PORT, DBNAME, "", "", QgsDataSourceUri.SslPrefer, AUTHCFG)
    else:
        uri.setConnection(HOST, PORT, DBNAME, USER, PASSWORD)
    return uri

def pg_layer(table, geom, key, name, group, live=False):
    uri = base_uri()
    uri.setDataSource(SCHEMA, table, geom, "", key)
    layer = QgsVectorLayer(uri.uri(False), name, "postgres")
    if not layer.isValid():
        print(f"!! Could not load {SCHEMA}.{table}. Check database credentials.")
        return None
    project.addMapLayer(layer, False)
    group.insertLayer(0, layer)          
    if live:
        LIVE_LAYERS.append(layer)
    return layer

def fill(rgb, outline, width="0.5", alpha=40, style="solid"):
    r, g, b = rgb
    return QgsFillSymbol.createSimple({"color": f"{r},{g},{b},{alpha}", "outline_color": outline,
                                       "outline_width": width, "outline_style": style})

def marker(shape, color, size, outline="#ffffff"):
    return QgsMarkerSymbol.createSimple({"name": shape, "color": color, "size": str(size),
                                         "outline_color": outline, "outline_width": "0.4"})

def label(layer, expr, size=10, bold=False, color="#111111", line=False):
    s = QgsPalLayerSettings()
    s.fieldName = expr
    s.isExpression = True
    f = QgsTextFormat()
    f.setSize(size)
    f.setColor(QColor(color))
    font = QFont()
    font.setBold(bold)
    f.setFont(font)
    buf = QgsTextBufferSettings()          
    buf.setEnabled(True)
    buf.setSize(1.2)
    buf.setColor(QColor("#ffffff"))
    f.setBuffer(buf)
    s.setFormat(f)
    if line:
        try:
            s.placement = QgsPalLayerSettings.Line
        except AttributeError:
            pass
    layer.setLabeling(QgsVectorLayerSimpleLabeling(s))
    layer.setLabelsEnabled(True)

def find_svg(rel_path):
    for base in QgsApplication.svgPaths():
        p = os.path.join(base, rel_path)
        if os.path.exists(p):
            return p
    return None

# ===================== A. TIDY THE EXISTING PROJECT ==========================
for name, scale in CLUTTER_LAYERS.items():
    for lyr in project.mapLayersByName(name):
        lyr.setScaleBasedVisibility(True)
        lyr.setMinimumScale(scale)       
        lyr.setMaximumScale(0)

for name in HIDE_BASEMAPS:
    for lyr in project.mapLayersByName(name):
        if REMOVE_HIDDEN:
            project.removeMapLayer(lyr.id())
        else:
            node = root.findLayer(lyr.id())
            if node:
                node.setItemVisibilityChecked(False)

live_group = root.insertGroup(0, "Live diversion analysis")
analysis_group = root.insertGroup(1, "Analysis")
reference_group = root.insertGroup(2, "Reference data")
basemap_group = root.insertGroup(3, "Basemaps")

def move_to_group(names, group):
    for name in names:
        for lyr in project.mapLayersByName(name):
            node = root.findLayer(lyr.id())
            if node and isinstance(node.parent(), QgsLayerTree):
                group.addChildNode(node.clone())
                root.removeChildNode(node)

move_to_group(GROUP_ANALYSIS, analysis_group)
move_to_group(GROUP_REFERENCE, reference_group)
move_to_group(GROUP_BASEMAPS, basemap_group)

# ============================ B. LIVE POSTGIS LAYERS ==========================
airspace = pg_layer("airspace", "boundary", "airspace_id", "FAA airspace (illustrative)", reference_group)
if airspace:
    kinds = {"SFRA": ((234, 179, 8), "#ca8a04", 15), "CLASS_B": ((59, 130, 246), "#2563eb", 40),
             "CLASS_C": ((217, 70, 239), "#a21caf", 40), "CLASS_D": ((6, 182, 212), "#0e7490", 40),
             "FRZ": ((249, 115, 22), "#c2410c", 40), "PROHIBITED": ((239, 68, 68), "#b91c1c", 45)}
    airspace.setRenderer(QgsCategorizedSymbolRenderer("kind", [
        QgsRendererCategory(k, fill(rgb, ln, alpha=a), k) for k, (rgb, ln, a) in kinds.items()]))
    airspace.setMapTipTemplate('<b>[% "name" %]</b><br>[% "kind" %]: [% "floor_ft_msl" %] to [% "ceiling_ft_msl" %] ft MSL')
    airspace.setScaleBasedVisibility(True)
    airspace.setMinimumScale(4_000_000)
    airspace.setMaximumScale(0)

buffer150 = pg_layer("regional_buffer_150nm", "geom", "id", "150 NM buffer (geodesic)", analysis_group)
if buffer150:
    buffer150.setRenderer(QgsSingleSymbolRenderer(
        fill((0, 0, 0), "#444444", width="0.7", alpha=0, style="dash")))

rings = pg_layer("range_rings", "geom", "ring_nm", "Range rings (NM)", live_group, live=True)
if rings:
    rings.setRenderer(QgsSingleSymbolRenderer(
        QgsLineSymbol.createSimple({"color": "#475569", "width": "0.5", "line_style": "dash"})))
    label(rings, '"ring_nm" || \' NM\'', size=9, color="#334155", line=True)

div_rings = pg_layer("diversion_top3_rings", "geom", "rank", "Diversion rings (20 NM)", live_group, live=True)
if div_rings:
    div_rings.setRenderer(QgsSingleSymbolRenderer(fill((249, 115, 22), "#ea580c", width="0.7", alpha=28)))

legs = pg_layer("diversion_legs", "geom", "rank", "Diversion legs", live_group, live=True)
if legs:
    legs.setRenderer(QgsSingleSymbolRenderer(
        QgsLineSymbol.createSimple({"color": "#ea580c", "width": "0.6", "line_style": "dot"})))
    label(legs, '"ident" || \'  \' || "dist_nm" || \' NM / \' || "eta_min" || \' min\'',
          size=9, color="#9a3412", line=True)

top3 = pg_layer("diversion_top3", "geom", "rank", "Top 3 diversion airports (live)", live_group, live=True)
if top3:
    top3.setRenderer(QgsSingleSymbolRenderer(marker("hexagon", "#f97316", 6, outline="#7c2d12")))
    label(top3, '"rank" || \'  \' || "ident"', size=12, bold=True, color="#7c2d12")
    top3.setDisplayExpression('"ident"')
    top3.setMapTipTemplate(
        '<b>#[% "rank" %]  [% "ident" %] - [% "name" %]</b><br>'
        'Longest runway: [% "longest_runway_ft" %] ft<br>'
        '[% "dist_nm" %] NM at [% "bearing_deg" %] deg, ETA [% "eta_min" %] min<br>'
        'Elevation: [% "elevation_ft" %] ft')

aircraft = pg_layer("aircraft_position", "geom", "callsign", "Aircraft (live)", live_group, live=True)
if aircraft:
    svg = find_svg(os.path.join("transport", "transport_airport.svg"))
    if svg:
        sl = QgsSvgMarkerSymbolLayer(svg)
        sl.setSize(7)
        sl.setFillColor(QColor("#0f172a"))
        sl.setStrokeColor(QColor("#ffffff"))
        sl.setDataDefinedProperty(QgsSymbolLayer.PropertyAngle,
                                  QgsProperty.fromExpression(f'"heading_deg" + {PLANE_ANGLE_OFFSET}'))
        sym = QgsMarkerSymbol([sl])
    else:
        sym = marker("arrow", "#0f172a", 6)
        sym.symbolLayer(0).setDataDefinedProperty(
            QgsSymbolLayer.PropertyAngle, QgsProperty.fromExpression('"heading_deg"'))
    aircraft.setRenderer(QgsSingleSymbolRenderer(sym))
    label(aircraft, '"callsign"', size=10, bold=True)
    aircraft.setMapTipTemplate('<b>[% "callsign" %]</b><br>Heading [% "heading_deg" %] deg, [% "groundspeed_kt" %] kt')

# ======================= C. WEATHER AND PROJECT CRS ===========================
if ADD_WEATHER:
    wx = QgsRasterLayer(
        "contextualWMSLegend=0&crs=EPSG:3857&dpiMode=7&featureCount=10&format=image/png"
        "&layers=nexrad-n0q-900913&styles&url=https://iastate.edu",
        "NEXRAD radar (Iowa Mesonet)", "wms")
    if wx.isValid():
        wx.setOpacity(0.6)
        project.addMapLayer(wx, False)
        reference_group.insertLayer(0, wx)
        node = root.findLayer(wx.id())
        if node:
            node.setItemVisibilityChecked(WEATHER_VISIBLE)

if USE_DC_EQUIDISTANT_CRS:
    crs = QgsCoordinateReferenceSystem.fromProj(
        "+proj=aeqd +lat_0=38.8899 +lon_0=-77.0091 +x_0=0 +y_0=0 +datum=WGS84 +units=m +no_defs")
    if crs.isValid():


project.setCrs(crs)
project.setEllipsoid("EPSG:7030")
if buffer150:
canvas = iface.mapCanvas()
xf = QgsCoordinateTransform(buffer150.crs(), project.crs(), project)
canvas.setExtent(xf.transformBoundingBox(buffer150.extent()))
canvas.refresh()
if top3:
iface.setActiveLayer(top3)
iface.actionMapTips().setChecked(True)
=========================== LIVE ANIMATION ==================================
_timer = QTimer()
_state = {"p": 0.0, "step": 0.01}
def _exec(sql):
uri = base_uri()
conn = QgsProviderRegistry.instance().providerMetadata("postgres").createConnection(
uri.uri(False), {})
conn.executeSql(sql)
def _refresh():
for lyr in LIVE_LAYERS:
lyr.dataProvider().reloadData()
lyr.triggerRepaint()
def _tick():
_state["p"] = round(_state["p"] + _state["step"], 4)
if _state["p"] > 1.0:
stop_flight()
return
_exec(f"UPDATE {SCHEMA}.sim_flight SET progress = {_state['p']}")
_refresh()
def start_flight(start=0.30, step=0.01, interval_ms=800):
stop_flight()
_state.update(p=start, step=step)
_exec(f"UPDATE {SCHEMA}.sim_flight SET progress = {start}")
_refresh()
_timer.timeout.connect(_tick)
_timer.start(interval_ms)
def stop_flight():
_timer.stop()
try:
_timer.timeout.disconnect(_tick)
except TypeError:
pass
============================== D. PRINT LAYOUT ==============================
def make_layout():
mm = QgsUnitTypes.LayoutMillimeters
layout = QgsPrintLayout(project)
layout.initializeDefaults()
layout.setName("Diversion Analysis")
m = QgsLayoutItemMap(layout)
m.attemptMove(QgsLayoutPoint(5, 22, mm))
m.attemptResize(QgsLayoutSize(205, 160, mm))
m.setExtent(iface.mapCanvas().extent())
m.setFrameEnabled(True)
layout.addLayoutItem(m)
t = QgsLayoutItemLabel(layout)
t.setText(LAYOUT_TITLE)
f = QFont()
f.setPointSize(18)
f.setBold(True)
t.setFont(f)
t.attemptMove(QgsLayoutPoint(5, 6, mm))
t.attemptResize(QgsLayoutSize(285, 12, mm))
layout.addLayoutItem(t)
lg = QgsLayoutItemLegend(layout)
lg.setLinkedMap(m)
lg.setLegendFilterByMapEnabled(True)
lg.attemptMove(QgsLayoutPoint(215, 22, mm))
layout.addLayoutItem(lg)
sb = QgsLayoutItemScaleBar(layout)
sb.setLinkedMap(m)
sb.setStyle("Single Box")
sb.setUnits(QgsUnitTypes.DistanceNauticalMiles)
sb.setUnitLabel("NM")
sb.setNumberOfSegments(4)
sb.setNumberOfSegmentsLeft(0)
sb.setUnitsPerSegment(25)
sb.attemptMove(QgsLayoutPoint(8, 185, mm))
layout.addLayoutItem(sb)
na = QgsLayoutItemPicture(layout)
arrow = find_svg(os.path.join("arrows", "NorthArrow_02.svg"))
na.setPicturePath(arrow if arrow else ":/images/north_arrows/layout_default_north_arrow.svg")
na.attemptMove(QgsLayoutPoint(190, 24, mm))
na.attemptResize(QgsLayoutSize(16, 16, mm))
layout.addLayoutItem(na)
src = QgsLayoutItemLabel(layout)
src.setText(DATA_SOURCE_NOTE)
sf = QFont()
sf.setPointSize(8)
src.setFont(sf)
src.attemptMove(QgsLayoutPoint(5, 198, mm))
src.attemptResize(QgsLayoutSize(285, 8, mm))
layout.addLayoutItem(src)
project.layoutManager().addLayout(layout)
try:
iface.openLayoutDesigner(layout)
except Exception:
pass
return layout
if MAKE_LAYOUT:
make_layout()
print("Done. Type start_flight() in the console to animate; stop_flight() to stop.")

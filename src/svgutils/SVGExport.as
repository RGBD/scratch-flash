/*
 * Scratch Project Editor and Player
 * Copyright (C) 2014 Massachusetts Institute of Technology
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
 */

// SVGExport.as
// John Maloney, June 2012.
//
// Convert an SVGElement tree into SVG file data (string or ByteArray).
//
// The client must be sure that the following are correct:
//	* 'text' field of text elements
//	* 'bitmap' field of image elements
//	* 'path' field of shape elements (the 'd' attribute is ignored)
//	* 'subElements' field of group elements
//	* 'transform' field (null if element is not transformed)
//	* gradient fills: an SVGElement with a 'stop' subElement for each color

package svgutils {
	import flash.display.Sprite;
	import flash.geom.*;
	import flash.utils.ByteArray;
	import util.Base64Encoder;
	import by.blooddy.crypto.image.PNG24Encoder;
	import by.blooddy.crypto.image.PNGFilter;

public class SVGExport {

	private var rootEl:SVGElement;
	private var rootNode:XML;
	private var defsNode:XML;
	private var nextID:int;

	public function SVGExport(svgRoot:SVGElement) {
		// Create an instance on the given SVG element, assumed to be an <svg> or <g> element.
		rootEl = svgRoot;
	}

	public function svgData():ByteArray {
		// Return the exported SVG file as a byte array.
		var s:String = svgString();
		var data: ByteArray = new ByteArray();
		data.writeUTFBytes(s);
		return data;
	}

	public function svgString():String {
		// Return the exported SVG file as a string.
		defsNode = null;
		nextID = 1;
		XML.ignoreComments = false;
		rootNode = new XML("<svg xmlns='http://www.w3.org/2000/svg' version='1.1' " +
				"xmlns:xlink='http://www.w3.org/1999/xlink'>\n" +
				"<!-- Exported by Scratch - http://scratch.mit.edu/ -->\n"+
			"</svg>");
		setSVGWidthAndHeight();
		for each (var subEl:SVGElement in rootEl.subElements) {
			addNodeTo(subEl, rootNode);
		}
		if (defsNode) rootNode.prependChild(defsNode); // add defs node, if needed
		return rootNode.toXMLString();
	}

	private function setSVGWidthAndHeight():void {
		// Set the attributes of the top-level <svg> element.
		var svgSprite:Sprite = new SVGDisplayRender().renderAsSprite(rootEl);
		var r:Rectangle = svgSprite.getBounds(svgSprite);
		var w:int = Math.ceil(r.x + r.width);
		var h:int = Math.ceil(r.y + r.height);
		rootNode.@width = w;
		rootNode.@height = h;
		if ((Math.floor(r.x) != 0) || (Math.floor(r.y) != 0)) {
			rootNode.@viewBox = '' + Math.floor(r.x) + ' ' + Math.floor(r.y) + ' ' + Math.ceil(w) + ' ' + Math.ceil(h);
		}
	}

	private function addNodeTo(el:SVGElement, xml:XML):void {
		if ('g' == el.tag) addGroupNodeTo(el, xml);
		else if ('image' == el.tag) addImageNodeTo(el, xml);
		else if ('text' == el.tag) addTextNodeTo(el, xml);
		else if (el.path) addPathNodeTo(el, xml);
		else trace('SVGExport unhandled: ' + el.tag);
	}

	private function addGroupNodeTo(el:SVGElement, xml:XML):void {
		if (el.subElements.length == 0) return;
		var node:XML = createNode(el, []);
		for each (var subEl:SVGElement in el.subElements) {
			addNodeTo(subEl, node);
		}
		setTransform(el, node);
		xml.appendChild(node);
	}

	private function addImageNodeTo(el:SVGElement, xml:XML):void {
		if (el.bitmap == null) return;
		const attrList:Array = ['x', 'y', 'width', 'height', 'opacity', 'scratch-type'];
		var node:XML = createNode(el, attrList);
		var pixels:ByteArray = PNG24Encoder.encode(el.bitmap, PNGFilter.PAETH);
		node.@['xlink:href'] = 'data:image/png;base64,' + Base64Encoder.encode(pixels);
		setTransform(el, node);
		xml.appendChild(node);
	}

	private function addPathNodeTo(el:SVGElement, xml:XML):void {
		if (el.path == null) return;
		const attrList:Array = ['fill', 'stroke', 'stroke-width', 'stroke-linecap', 'stroke-linejoin', 'opacity', 'scratch-type'];
		var node:XML = createNode(el, attrList);
		node.setName('path');
		node.@['d'] = pathCmds(el.path);
		setTransform(el, node);
		xml.appendChild(node);
	}

	static public function pathCmds(cmdList:Array):String {
		// Convert an array of path commands into a 'd' attribute string.
		var result:String = '';
		for each (var cmd:Array in cmdList) {
			var args:Array = cmd.slice(1);
			var argsString:String = '';
			for (var i:int = 0; i < args.length; i++) {
				var n:Number = args[i];
				argsString += ' ' + (n == int(n) ? n : Number(n).toFixed(3));
			}
			result += cmd[0] + argsString + ' ';
		}
		return result;
	}

	private function addTextNodeTo(el:SVGElement, xml:XML):void {
		if (!el.text) return;
		var s:String = el.text.replace(/\s+$/g, ''); // remove trailing whitespace
		if (s.length == 0) return; // don't save empty text element
		var stroke:* = el.getAttribute('stroke', null);
		if (stroke) el.setAttribute('fill', stroke);
		const attrList:Array = [
			'fill', 'stroke', 'opacity', 'x', 'y', 'dx', 'dy', 'text-anchor',
			'font-family', 'font-size', 'font-style', 'font-weight'];
		var node:XML = createNode(el, attrList);
		node.text()[0] = s;
		setTransform(el, node);
		xml.appendChild(node);
	}

	private function createNode(el:SVGElement, attrList:Array = null):XML {
		// Return a new XML node for the given element. Set the node type
		// from the element tag and copy the given attributes from the
		// element attributes into the new node, skipping any that are
		// not defined and converting any numeric color attributes into
		// SVG hex strings of the form #HHHHHH. Attributes who values are
		// SVGElement (e.g. gradients) are skipped here and handled elsewhere.
		var colorAttributes:Array = ['fill', 'stroke'];
		var node:XML = new XML('<placeholder> </placeholder>');
		node.setName(el.tag);
		node.@id = el.id;
		for each (var k:String in attrList) {
			// Save attributes that are defined but not SVGElements (e.g. gradients).
			var val:* = el.getAttribute(k);
			if (val is Number && (colorAttributes.indexOf(k) > -1)) val = SVGElement.colorToHex(val);
			if (val is SVGElement) {
				if ('fill' == k || 'stroke' == k) val = defineGradient(val);
				else val = null; // skip SVGElement values other than gradient fills
			}
			if (val) node.@[k] = val;
		}
		return node;
	}

	// Transforms

	private function setTransform(el:SVGElement, node:XML):void {
		// Returns transformation in the most human-readable format possible
		// The resulting sequense of commands is the following:
		// translate(c) scale(s) skewY(y) rotate(r) tranlate(d) translate(t)
		// where: (c) centers the image, so (s, y, r) transform produce no shifting;
		// (d) decenters the image, has opposite to (c) parameters;
		// (t) stands for explicit, user-made translation
		// if any of (c, d) (s) (y) (r) (t) is insignificant, it's command is ommited.
		// Note! The SVG standard requires commands being written in reverse order.
		// Matrices: m - current transform matrix being dissolved
		// f - auxilary matrix, used to compute the (t)
		var temp:Matrix = el.transform.clone();
		el.transform = new Matrix();
		var svgSprite:Sprite = new SVGDisplayRender().renderAsSprite(el);
		var bounds:Rectangle = svgSprite.getBounds(svgSprite);
		const elCenter:Point = new Point(bounds.x + bounds.width / 2, bounds.y + bounds.height / 2);
		el.transform = temp;
		var m:Matrix = el.transform.clone();
		var d:Point = new Point(elCenter.x, elCenter.y);
		var decentering:String = (Point.distance(d, new Point()) < 1) ? "" :
				"translate(" + d.x.toFixed(2) + " " + d.y.toFixed(2) + ") ";
		var c:Point = new Point(-elCenter.x, -elCenter.y);
		var centering:String = (Point.distance(c, new Point()) < 1) ? "" :
				"translate(" + c.x.toFixed(2) + " " + c.y.toFixed(2) + ") ";
		var r:Number = Math.atan2(m.b, m.a);
		var rotating:String = (Math.abs(r / Math.PI * 180) < 1) ? "" :
				"rotate(" + (r / Math.PI * 180).toFixed(0) + ") ";
		m.rotate(-r);
		var w:Number = Math.atan(m.c / m.d);
		var skewingX:String = (Math.abs(w / Math.PI * 180) < 1) ? "" :
				"skewX(" + (w / Math.PI * 180).toFixed(0) + ") ";
		temp = new Matrix();
		temp.c = Math.tan(-w);//unskew
		m.concat(temp);
		var s:Point = new Point(m.a, m.d);
		var scaling:String = (Point.distance(s, new Point(1, 1)) < 1e-3) ? "" :
				"scale(" + s.x.toFixed(3) + ((Math.abs(s.y / s.x - 1) < 1e-3) ? "" : " " + s.y.toFixed(3)) + ") ";
		m.scale(1 / m.a, 1 / m.d);
		var f:Matrix = new Matrix();
		f.translate(c.x, c.y);
		f.scale(s.x, s.y);
		temp = new Matrix();
		temp.c = Math.tan(w);
		f.concat(temp);
		f.rotate(r);
		f.translate(d.x, d.y);
		var t:Point = new Point(el.transform.tx - f.tx, el.transform.ty - f.ty);
		var translating:String = (Point.distance(t, new Point()) < 1) ? "" :
				"translate(" + t.x.toFixed(2) + " " + t.y.toFixed(2) + ") ";
		var transforming:String = rotating + skewingX + scaling;
		if (transforming != "") {
			transforming = decentering + transforming + centering;
		}
		transforming = translating + transforming;
		if (transforming == "") return;
		node.@['transform'] = transforming;
	}

	// Gradients

	private function defineGradient(gradEl:SVGElement):String {
		// Create a definition for the given gradient element and
		// return an internal URL reference to it. Return null if
		// the element is not a gradient.
		var node:XML
		if (gradEl.tag == 'linearGradient') {
			node = createNode(gradEl, ['x1', 'y1', 'x2', 'y2', 'gradientUnits']);
		} else if (gradEl.tag == 'radialGradient') {
			node = createNode(gradEl, ['cx', 'cy', 'r', 'fx', 'fy', 'gradientUnits']);
		} else {
			return null;
		}
		node.@id = 'grad_' + nextID++;

		for each (var subEl:SVGElement in gradEl.subElements) {
			var stopNode:XML = new XML('<stop> </stop>');
			stopNode.@['offset'] = subEl.getAttribute('offset', 0)
			stopNode.@['stop-color'] = subEl.getAttribute('stop-color', 0);
			var opacity:* = subEl.getAttribute('stop-opacity');
			if (typeof opacity != 'undefined' && opacity !== null) stopNode.@['stop-opacity'] = opacity;
			node.appendChild(stopNode);
		}
		addDefinition(node);
		return 'url(#' + node.@id + ')';
	}

	private function addDefinition(node:XML):void {
		// Add the given node to the defs node, creating the defs node if necessary.
		if (!defsNode) defsNode = new XML('<defs> </defs>');
		defsNode.appendChild(node);
	}

}}

﻿package jehovah3d.core
{
	import jehovah3d.Jehovah;
	import jehovah3d.core.background.BitmapTextureBG;
	import jehovah3d.core.background.LinearColorBG;
	import jehovah3d.core.light.FreeLight3D;
	import jehovah3d.core.mesh.Mesh;
	import jehovah3d.core.renderer.AddMultiTextureRenderer;
	import jehovah3d.core.renderer.DisplayTextureRenderer;
	import jehovah3d.core.renderer.Renderer;
	import jehovah3d.core.renderer.SSAORenderer;
	import jehovah3d.util.HexColor;

	import com.fuwo.math.Ray3D;

	import flash.display.BitmapData;
	import flash.display3D.Context3DCompareMode;
	import flash.display3D.Context3DTextureFormat;
	import flash.display3D.textures.Texture;
	import flash.display3D.textures.TextureBase;
	import flash.geom.Matrix3D;
	import flash.geom.Point;
	import flash.geom.Vector3D;
	import flash.utils.Dictionary;
	import flash.utils.getTimer;

	public class Camera3D extends Object3D
	{
		private var _viewWidth:int;
		private var _viewHeight:int;
		private var _viewScale:Number = 1; //画布缩放比例。从此相机不再使用scaleX、scaleY
		private var _view:View;
		private var _zNear:Number;
		private var _zFar:Number;
		private var _fov:Number; //radius.
		private var _focalLength:Number;
		private var _orthographic:Boolean = false;
		private var _screenShot:BitmapData;
		private var _pm:Matrix3D;
		private var _pmChanged:Boolean;
		private var _configBackBufferNeeded:Boolean = true;
		private var _context3DProperty:Context3DProperty;
		private var _bgColor:HexColor;
		protected var _renderList:Vector.<Object3D> = new Vector.<Object3D>();
		
		private var _fps:uint = 0;
		private var _objs:uint = 0;
		private var _tris:uint = 0;
		private var _verts:uint = 0;
		private var _oldTime:int = -1;
		private var _newTime:int;
		public var stepLength:Number = 10;
		
		public var wfPickable:Boolean = true;
		public var wfPickTolerance:Number = 12;
		
		private var ssaoTexture:Texture;
		private var ambientAndReflectionTexture:Texture;
		private var depthTexture:Texture;
		private var normalTexture:Texture;
		public var rendererDict:Dictionary = new Dictionary();
		
		public function Camera3D(viewWidth:Number, viewHeight:Number, zNear:Number, zFar:Number, fov:Number = Math.PI / 2, orthographic:Boolean = false, bgColor:uint = 0xFFFFFF)
		{
			_viewWidth = viewWidth;
			_viewHeight = viewHeight;
			_view = new View(_viewWidth, _viewHeight);
			_zNear = zNear;
			_zFar = zFar;
			_fov = fov;
			_focalLength = _viewWidth * 0.5 / Math.tan(_fov * 0.5);
			_orthographic = orthographic;
			_bgColor = new HexColor(bgColor, 1.0);
			_pm = new Matrix3D();
			_pmChanged = true;
			_context3DProperty = new Context3DProperty();
		}
		
		/**
		 * 渲染灯光的深度图
		 * 
		 */		
		private function renderLightDepthTexture():void
		{
			var i:int;
			var j:int;
			for(i = 0; i < Jehovah.lights.length; i ++)
				if(Jehovah.lights[i].useShadow)
				{
					Jehovah.currentLight = Jehovah.lights[i];
					Jehovah.lights[i].calculateProjectionMatrix();
					for(j = 0; j < _renderList.length; j ++)
						if(_renderList[j] is Mesh)
						{
							_renderList[j].localToCameraMatrix.copyFrom(_renderList[j].localToGlobalMatrix);
							_renderList[j].localToCameraMatrix.append(Jehovah.lights[i].globalToLocalMatrix);
							_renderList[j].finalMatrix.copyFrom(_renderList[j].localToCameraMatrix);
							_renderList[j].finalMatrix.append(Jehovah.lights[i].projectionMatrix);
						}
					if(!Jehovah.lights[i].depthTexture)
						Jehovah.lights[i].depthTexture = Jehovah.context3D.createTexture(Jehovah.lights[i].shadowmappingsize, Jehovah.lights[i].shadowmappingsize, Context3DTextureFormat.BGRA, true);
					Jehovah.context3D.setRenderToTexture(Jehovah.lights[i].depthTexture, true, 0, 0);
					Jehovah.context3D.clear(1, 0, 0, 1);
					Jehovah.renderMode = Jehovah.RENDER_DEPTH;
					draw();
				}
			Jehovah.currentLight = null;
		}
		
		private function updateLightHeads():void
		{
			var i:int;
			for(i = 0; i < Jehovah.lights.length; i ++)
				if(Jehovah.lights[i] is FreeLight3D)
					FreeLight3D(Jehovah.lights[i]).updateLightHead();
		}
		
		/**
		 * 检查是否需要设置渲染缓冲区, 搜集场景中的Mesh
		 * 
		 */		
		protected function beforeRender():void
		{
			if(_oldTime == -1)
				_oldTime = getTimer();
			if(_configBackBufferNeeded)
			{
				Jehovah.context3D.configureBackBuffer(_viewWidth, _viewHeight, 4, true);
				_configBackBufferNeeded = !_configBackBufferNeeded;
			}
			if(_pmChanged)
				updatePM();
		}
		protected function collectMeshes():void
		{
			_renderList.length = 0;
			Jehovah.scene.collectRenderList(_renderList);
			_renderList.sort(sortFunction);
		}
		
		/**
		 * 根据相机和投影矩阵更新场景中物体的矩阵
		 * @param viewObj
		 * @param projectMatrix
		 * 
		 */		
		protected function updateMatrices(viewObj:Object3D, projectMatrix:Matrix3D):void
		{
			//更新matrix, inverseMatrix, localToGlobalMatrix, globalToLocalMatrix
			Jehovah.scene.updateMatrix();
			Jehovah.scene.localToGlobalMatrix.copyFrom(Jehovah.scene.matrix);
			Jehovah.scene.globalToLocalMatrix.copyFrom(Jehovah.scene.inverseMatrix);
			Jehovah.scene.updateHierarchyMatrix_LocalGlobal();
			
			//更新localToCameraMatrix, finalMatrix
			Jehovah.scene.localToCameraMatrix.copyFrom(Jehovah.scene.localToGlobalMatrix);
			Jehovah.scene.localToCameraMatrix.append(viewObj.globalToLocalMatrix);
			Jehovah.scene.finalMatrix.copyFrom(Jehovah.scene.localToCameraMatrix);
			Jehovah.scene.finalMatrix.append(projectMatrix);
			Jehovah.scene.updateHierarchyMatrix_CameraFinal();
		}
		
		private function renderAmbientAndReflectionTexture():void
		{
			if(!ambientAndReflectionTexture)
				ambientAndReflectionTexture = Jehovah.context3D.createTexture(1024, 1024, Context3DTextureFormat.BGRA, true);
			Jehovah.renderMode = Jehovah.RENDER_AMBIENTANDREFLECTION;
			Jehovah.context3D.setRenderToTexture(ambientAndReflectionTexture, true, 0, 0);
			Jehovah.context3D.clear(_bgColor.fractionalRed, _bgColor.fractionalGreen, _bgColor.fractionalBlue, 1);
			draw();
		}
		
		private function renderDiffuseAndSpecular():void
		{
			var i:int;
			for(i = 0; i < Jehovah.lights.length; i ++)
			{
				Jehovah.currentLight = Jehovah.lights[i];
				if(!Jehovah.lights[i].diffuseAndSpecularTexture)
					Jehovah.lights[i].diffuseAndSpecularTexture = Jehovah.context3D.createTexture(1024, 1024, Context3DTextureFormat.BGRA, true);
				Jehovah.context3D.setRenderToTexture(Jehovah.lights[i].diffuseAndSpecularTexture, true, 0, 0);
				Jehovah.context3D.clear(0, 0, 0, 1);
				Jehovah.renderMode = Jehovah.RENDER_DIFFUSEANDSEPCULAR;
				draw();
			}
			Jehovah.currentLight = null;
		}
		
		private function renderFinal():void
		{
			Jehovah.context3D.setRenderToBackBuffer();
			Jehovah.context3D.clear(_bgColor.fractionalRed, _bgColor.fractionalGreen, _bgColor.fractionalBlue, 1);
			
			var textures:Vector.<TextureBase> = new Vector.<TextureBase>();
			var i:int;
			for(i = 0; i < Jehovah.lights.length; i ++)
				textures.push(Jehovah.lights[i].diffuseAndSpecularTexture);
			
			var no:String = AddMultiTextureRenderer.NAME;
			if(!rendererDict[no])
				rendererDict[no] = new AddMultiTextureRenderer(null);
			AddMultiTextureRenderer(rendererDict[no]).ambientAndReflectionTexture = ambientAndReflectionTexture;
			AddMultiTextureRenderer(rendererDict[no]).diffuseAndSpecularTextures = textures;
			AddMultiTextureRenderer(rendererDict[no]).aoTexture = Jehovah.useSSAO ? ssaoTexture : null;
			Renderer(rendererDict[no]).render(Jehovah.context3D, context3DProperty);
		}
		
		/**
		 * 统计数据，将数据更新到相机的diagram上
		 * 
		 */		
		protected function afterRender():void
		{
			if(_drawToBitmapData)
			{
				_screenShot = new BitmapData(_viewWidth, _viewHeight, false);
				Jehovah.context3D.drawToBitmapData(_screenShot);
			}
			Jehovah.context3D.present();
			_fps ++;
			_newTime = getTimer();
			if(_newTime - _oldTime >= 1000)
			{
				var i:uint;
				for(i = 0; i < _renderList.length; i ++)
				{
					if(_renderList[i] is Mesh && Mesh(_renderList[i]).geometry)
					{
						_objs ++;
						_tris += Mesh(_renderList[i]).geometry.numTriangle;
						_verts += Mesh(_renderList[i]).geometry.numVertices;
					}
				}
				_view.updateDiagram(_fps, _objs, _tris, _verts, _viewWidth, _viewHeight);
				_oldTime = _newTime;
				_fps = 0;
				_objs = 0;
				_tris = 0;
				_verts = 0;
			}
		}
		
		private function get useShadow():Boolean
		{
			var i:int;
			for(i = 0; i < Jehovah.lights.length; i ++)
				if(Jehovah.lights[i].useShadow)
					return true;
			return false;
		}
		
		public function render():void
		{
			if(Jehovah.context3D.driverInfo == "Disposed")
				return ;
			
			beforeRender();
			collectMeshes();
			
			if(Jehovah.useDefaultLight)
			{
				updateMatrices(this, _pm);
				Jehovah.context3D.setRenderToBackBuffer();
				Jehovah.context3D.clear(_bgColor.fractionalRed, _bgColor.fractionalGreen, _bgColor.fractionalBlue, _bgColor.fractionalAlpha);
				Jehovah.renderMode = Jehovah.RENDER_ALL;
				draw();
			}
			else
			{
				updateMatrices(this, _pm);
				updateLightHeads();
				renderAmbientAndReflectionTexture();
				if(Jehovah.useSSAO)
					renderSSAO();
				renderLightDepthTexture();
				updateMatrices(this, _pm);
				renderDiffuseAndSpecular();
				Jehovah.context3D.setBlendFactors("one", "zero");
				renderFinal();
			}
			
			afterRender();
		}
		
		private function displayTexture(texture:Texture):void
		{
			Jehovah.context3D.setRenderToBackBuffer();
			Jehovah.context3D.clear(_bgColor.fractionalRed, _bgColor.fractionalGreen, _bgColor.fractionalBlue, 1);
			
			var no:String = DisplayTextureRenderer.NAME;
			if(!rendererDict[no])
				rendererDict[no] = new DisplayTextureRenderer(null);
			DisplayTextureRenderer(rendererDict[no]).texture = texture;
			Renderer(rendererDict[no]).render(Jehovah.context3D, context3DProperty);
		}
		
		private function renderSSAO():void
		{
			if(!depthTexture)
				depthTexture = Jehovah.context3D.createTexture(1024, 1024, Context3DTextureFormat.BGRA, true);
			if(!normalTexture)
				normalTexture = Jehovah.context3D.createTexture(1024, 1024, Context3DTextureFormat.BGRA, true);
			
			Jehovah.context3D.setRenderToTexture(depthTexture, true, 0, 0);
			Jehovah.context3D.clear(1, 0, 0, 1);
			Jehovah.renderMode = Jehovah.RENDER_DEPTH;
			draw();
			
			Jehovah.context3D.setRenderToTexture(normalTexture, true, 0, 0);
			Jehovah.context3D.clear(0.5, 0.5, 1, 1);
			Jehovah.renderMode = Jehovah.RENDER_NORMAL;
			draw();
			
			if(!ssaoTexture)
				ssaoTexture = Jehovah.context3D.createTexture(1024, 1024, Context3DTextureFormat.BGRA, true);
			Jehovah.context3D.setRenderToTexture(ssaoTexture, true, 0, 0);
			Jehovah.context3D.clear(1, 1, 1, 1);
			
			var no:String = SSAORenderer.NAME;
			if(!rendererDict[no])
				rendererDict[no] = new SSAORenderer(null);
			SSAORenderer(rendererDict[no]).depthTexture = depthTexture;
			SSAORenderer(rendererDict[no]).normalTexture = normalTexture;
			Renderer(rendererDict[no]).render(Jehovah.context3D, context3DProperty);
		}
		
		/**
		 * 投影矩阵。考虑viewScale进去。
		 * 
		 */		
		private function updatePM():void
		{
			/*
			final = pm * globalToCamera * globalPoint
			globalToCamera = invert(Mcamera) = invert(Mcamera_t*Mcamera_r*Mcamera_s)
			=invert(Mcamera_s)*invert(Mcamera_r)*invert(Mcamera_t)
			
			==>
			final = pm * invert(Mcamera_s) * invert(Mcamera_noscale) * globalPoint
			pm * invert(Mcamera_s) = pm * Mcamera_viewScale
			*/
			_focalLength = _viewWidth * 0.5 / Math.tan(_fov * 0.5);
			if(_orthographic)
			{
				_pm.copyRawDataFrom(Vector.<Number>([
					2.0 / _viewWidth, 0.0, 0.0, 0.0, 
					0.0, 2.0 / _viewHeight, 0.0, 0.0, 
					0.0, 0.0, 1.0 / (_zNear - _zFar), 0.0, 
					0.0, 0.0, _zNear / (_zNear - _zFar), 1.0
				]));
			}
			else
			{
				var xScale:Number = 1.0 / Math.tan(_fov / 2.0);
				var yScale:Number = xScale * _viewWidth / _viewHeight;
				_pm.copyRawDataFrom(Vector.<Number>([
					xScale, 0.0, 0.0, 0.0, 
					0.0, yScale, 0.0, 0.0, 
					0.0, 0.0, _zFar / (_zNear - _zFar), -1.0, 
					0.0, 0.0, (_zNear * _zFar) / (_zNear - _zFar), 0.0
				]));
			}
			
			var viewScaleMatrix:Matrix3D = new Matrix3D();
			viewScaleMatrix.appendScale(_viewScale, _viewScale, 1);
			_pm.prepend(viewScaleMatrix);
		}
		
		protected function draw():void
		{
			var i:int;
			
			//使用depthTest进行渲染。
			Jehovah.context3D.setDepthTest(true, Context3DCompareMode.LESS);
			for(i = 0; i < _renderList.length; i ++)
			{
				if(_renderList[i] is Mesh)
					Mesh(_renderList[i]).render(Jehovah.context3D, context3DProperty);
				else if(_renderList[i] is LinearColorBG || _renderList[i] is BitmapTextureBG)
					Object(_renderList[i]).render(Jehovah.context3D, context3DProperty);
			}
		}
		
		private function sortFunction(m0:Object3D, m1:Object3D):int
		{
			if(m0.renderPriority < m1.renderPriority)
				return -1;
			else if(m0.renderPriority > m1.renderPriority)
				return 1;
			return 0;
		}
		
		/**
		 * move forward on planar parallel with XOY. 
		 * 
		 */		
		public function moveForward():void
		{
			var movable:Boolean = false;
			if(!Jehovah.enableCollisionDetection)
				movable = true;
			else
			{
				var ray:Ray3D = new Ray3D(new Vector3D(x, y, z), new Vector3D(Math.cos(Math.PI * 0.5 + _rotationZ), Math.sin(Math.PI * 0.5 + _rotationZ), 0));
				ray.length = stepLength;
				if(!Jehovah.scene.routeBlocked(ray))
					movable = true;
			}
			if(movable)
			{
				x += Math.cos(Math.PI * 0.5 + _rotationZ) * stepLength;
				y += Math.sin(Math.PI * 0.5 + _rotationZ) * stepLength;
			}
		}
		
		/**
		 * move backward on planar parallel with XOY.  
		 * 
		 */		
		public function moveBackward():void
		{
			var movable:Boolean = false;
			if(!Jehovah.enableCollisionDetection)
				movable = true;
			else
			{
				var ray:Ray3D = new Ray3D(new Vector3D(x, y, z), new Vector3D(-Math.cos(Math.PI * 0.5 + _rotationZ), -Math.sin(Math.PI * 0.5 + _rotationZ), 0));
				ray.length = stepLength;
				if(!Jehovah.scene.routeBlocked(ray))
					movable = true;
			}
			if(movable)
			{
				x -= Math.cos(Math.PI * 0.5 + _rotationZ) * stepLength;
				y -= Math.sin(Math.PI * 0.5 + _rotationZ) * stepLength;
			}
		}
		
		/**
		 * move left on planar parallel with XOY.  
		 * 
		 */		
		public function moveLeft():void
		{
			var movable:Boolean = false;
			if(!Jehovah.enableCollisionDetection)
				movable = true;
			else
			{
				var ray:Ray3D = new Ray3D(new Vector3D(x, y, z), new Vector3D(Math.cos(Math.PI + _rotationZ), Math.sin(Math.PI + _rotationZ), 0));
				ray.length = stepLength;
				if(!Jehovah.scene.routeBlocked(ray))
					movable = true;
			}
			if(movable)
			{
				x += Math.cos(Math.PI + _rotationZ) * stepLength;
				y += Math.sin(Math.PI + _rotationZ) * stepLength;
			}
		}
		
		/**
		 * move right on planar parallel with XOY.  
		 * 
		 */		
		public function moveRight():void
		{
			var movable:Boolean = false;
			if(!Jehovah.enableCollisionDetection)
				movable = true;
			else
			{
				var ray:Ray3D = new Ray3D(new Vector3D(x, y, z), new Vector3D(Math.cos(_rotationZ), Math.sin(_rotationZ), 0));
				ray.length = stepLength;
				if(!Jehovah.scene.routeBlocked(ray))
					movable = true;
			}
			if(movable)
			{
				x += Math.cos(_rotationZ) * stepLength;
				y += Math.sin(_rotationZ) * stepLength;
			}
		}
		
		/**
		 * 计算target本地坐标系的点localPoint在2D屏幕上的投影。若convertToStageCoordinateSystem，返回stageX，stageY；否则返回Camera.View下的坐标。
		 * @param target
		 * @param localPoint
		 * @param convertToStageCoordinateSystem
		 * @return 
		 * 
		 */		
		public function calculateProjection(target:Object3D, localPoint:Vector3D, convertToStageCoordinateSystem:Boolean):Point
		{
			var ret:Point;
			var v0:Vector3D = (target && target != this) ? target.localToCameraMatrix.transformVector(localPoint) : localPoint.clone();
//			if(v0.z > -_zNear || v0.z < -_zFar)
//				return null;
			if(_orthographic)
			{
				ret = new Point(v0.x * viewScale + _viewWidth * 0.5, _viewHeight * 0.5 - v0.y * viewScale);
				if (convertToStageCoordinateSystem)
					ret = _view.localToGlobal(ret);
			}
			else
			{
				var focalLength:Number = _viewWidth * 0.5 / Math.tan(_fov * 0.5);
				ret = new Point(-focalLength / v0.z * v0.x * viewScale, -focalLength / v0.z * v0.y * viewScale);
				ret.x += _viewWidth * 0.5;
				ret.y = _viewHeight * 0.5 - ret.y;
				if (convertToStageCoordinateSystem)
					ret = _view.localToGlobal(ret);
			}
			return ret;
		}
		
		private function disposeScreenShot():void
		{
			if(_screenShot)
			{
//				_screenShot.dispose();
				_screenShot = null;
			}
		}
		
		/**
		 * 计算到taget的初始距离。 
		 * @param bounding target的bounding
		 * @param margin 留白的百分比, 0 =< margin < 1
		 * 
		 */		
		public function calculateInitDistByTargetBounding(boundingRadius:Number, margin:Number):Number
		{
			/*
			alpha = min(hfov, vfov) * 0.5
			d * sin(beta) = bounding.r
			tan(beta) / tan(alpha) = 1 - margin
			
			==> tan(beta) = tan(alpah) * (1 - margin) 可以得到beta
			*/
			if(boundingRadius < 1)
				throw new Error("bounding error");
			
			var tan_alpha:Number;
			if(_viewWidth > _viewHeight)
				tan_alpha = Math.tan(_fov * 0.5) / _viewWidth * _viewHeight;
			else
				tan_alpha = Math.tan(_fov * 0.5);
			
			var beta:Number = Math.atan(tan_alpha * (1 - margin));
			return boundingRadius / Math.sin(beta);
		}
		
		/**
		 * view width. 
		 * @return 
		 * 
		 */		
		public function get viewWidth():int
		{
			return _viewWidth;
		}
		public function set viewWidth(val:int):void
		{
			if(_viewWidth != val)
			{
				if(val < 50)
					val = 50;
				_viewWidth = val;
				_pmChanged = true;
				_configBackBufferNeeded = true;
				_view.viewWidth = _viewWidth;
			}
		}
		
		/**
		 * view height. 
		 * @return 
		 * 
		 */		
		public function get viewHeight():int
		{
			return _viewHeight;
		}
		public function set viewHeight(val:int):void
		{
			if(_viewHeight != val)
			{
				if(val < 50)
					val = 50;
				_viewHeight = val;
				_pmChanged = true;
				_configBackBufferNeeded = true;
				_view.viewHeight = _viewHeight;
			}
		}
		public function get viewScale():Number
		{
			return _viewScale;
		}
		public function set viewScale(value:Number):void
		{
			if (value < 0 || value > 100) return ; //稍稍做一下限定，不要缩放得太过分
			if (_viewScale != value)
			{
				_viewScale = value;
				_pmChanged = true;
			}
		}
		public function get zNear():Number
		{
			return _zNear;
		}
		public function set zNear(value:Number):void
		{
			_zNear = value;
			_pmChanged = true;
		}
		public function get zFar():Number
		{
			return _zFar;
		}
		public function set zFar(value:Number):void
		{
			_zFar = value;
			_pmChanged = true;
		}
		public function get view():View
		{
			return _view;
		}
		/**
		 * fov. 
		 * @return 
		 * 
		 */		
		public function get fov():Number
		{
			return _fov;
		}
		public function set fov(val:Number):void
		{
			if(_fov != val)
			{
				_fov = val;
				_pmChanged = true;
			}
		}
		
		public function get focalLength():Number
		{
			return _focalLength;
		}
		public function get screenRatio():Number
		{
			return _viewWidth / _viewHeight;
		}
		
		/**
		 * orthographic. 
		 * @return 
		 * 
		 */		
		public function get orthographic():Boolean
		{
			return _orthographic;
		}
		public function set orthographic(val:Boolean):void
		{
			if(_orthographic != val)
			{
				_orthographic = val;
				_pmChanged = true;
			}
		}
		private var _drawToBitmapData:Boolean;
		public function get drawToBitmapData():Boolean { return _drawToBitmapData; }
		
		public function set drawToBitmapData(value:Boolean):void
		{
			if (_drawToBitmapData == value)
				return;
			_drawToBitmapData = value;
			if(!_drawToBitmapData)
				disposeScreenShot();
		}
		
		public function get screenShot():BitmapData
		{
			return _screenShot;
		}
		
		public function get pm():Matrix3D
		{
			return _pm;
		}
		public function get bgColor():HexColor
		{
			return _bgColor;
		}
		public function set bgColor(value:HexColor):void
		{
			_bgColor = value;
		}
		public function get configBackBufferNeeded():Boolean
		{
			return _configBackBufferNeeded;
		}
		public function set configBackBufferNeeded(val:Boolean):void
		{
			_configBackBufferNeeded = val;
		}
		public function get context3DProperty():Context3DProperty
		{
			return _context3DProperty;
		}
		
		/**
		 * 屏幕坐标系点到相机坐标系点的转化
		 * @param viewP
		 * @return 
		 * 
		 */		
		public function viewCSPointToCameraCSPoint(viewP:Point):Point
		{
			return new Point(viewP.x - viewWidth * 0.5, viewHeight * 0.5 - viewP.y);
		}
		
		/**
		 * 相机坐标系点到屏幕坐标系点的转化
		 * @param cameraP
		 * @return 
		 * 
		 */		
		public function cameraCSPointToViewCSPoint(cameraP:Point):Point
		{
			return new Point(viewWidth * 0.5 + cameraP.x, viewHeight * 0.5 - cameraP.y);
		}
		
		override public function dispose():void
		{
			super.dispose();
			if(_view)
				_view = null;
			if(_pm)
				_pm = null;
			if(_context3DProperty)
			{
				_context3DProperty.dispose(Jehovah.context3D);
				_context3DProperty = null;
			}
			if(_bgColor)
				_bgColor = null;
			if(_renderList)
			{
				_renderList.length = 0;
				_renderList = null;
			}
			disposeScreenShot();
			
			if(ambientAndReflectionTexture)
			{
				ambientAndReflectionTexture.dispose();
				ambientAndReflectionTexture = null;
			}
			if(depthTexture)
			{
				depthTexture.dispose();
				depthTexture = null;
			}
			if(normalTexture)
			{
				normalTexture.dispose();
				normalTexture = null;
			}
			for(var key:* in rendererDict)
			{
				rendererDict[key].dispose();
				delete rendererDict[key];
			}
		}
		
		override public function toString():String
		{
			return "[Camera3D:" + name + "]";
		}
	}
}
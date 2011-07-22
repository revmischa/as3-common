package biz.int80h
{
	import flash.events.EventDispatcher;
	import flash.net.URLVariables;
	import flash.utils.describeType;
	import flash.utils.getDefinitionByName;
	import flash.utils.getQualifiedClassName;
	
	import mx.collections.ArrayCollection;
	import mx.core.ClassFactory;
	import mx.rpc.events.FaultEvent;
	import mx.rpc.events.ResultEvent;
	import mx.utils.ObjectProxy;
	
	[Bindable] dynamic public class Entity extends EventDispatcher
	{
		// lists of singletons by class
		protected static var _entities:Object = {};
		
		// the actual singletons by class / pk
		protected static var _singletons:Object = {};
		
		// should all entities created be singletons?
		// this does not affect singleton ArrayCollections accessed with all()
		public static var USE_SINGLETONS_ONLY:Boolean = true;

		public static var DEBUG:Boolean = false;

		// constructor
		public function Entity(fields:Object=null) {
			this.setFields(fields);
		}
		
		
		// override in subclass
		// entity class name and REST path
		// maybe can be _classIdentifier?
		public virtual function get className():String { return "noclass" };
		
		// trace if DEBUG
		protected static function debug(str:String):void {
			if (! DEBUG) return;
			trace(str);
		}
		
		//// fields
		
		// returns value of a field
		[Bindable(event="FieldsChanged")] public function field(fieldName:String):* {
			if (! this.hasOwnProperty(fieldName))
				return undefined;
			 
			return this[fieldName];
		}
		
		// field setter for an Entity instance
		public function setField(fieldName:String, value:Object, fireFieldsChangedEvent:Boolean=true):void {
			if (value is ObjectProxy) {
				// get class and type info for this field
				var type:String = getQualifiedClassName(this[fieldName]);
				var typeInfo:Object = describeType(this);
				
				// try normal property
				var typeName:String = typeInfo..variable.(@name == fieldName).@type;
				
				if (! typeName) {
					// try bindable accessor method
					typeName = typeInfo..accessor.(@name == fieldName).@type;
				}
				
				if (! typeName) {
					// failed to find it
					trace("failed to find type info for " + type + "." + fieldName);
					return;
				}
				
				var typeClass:Class = getDefinitionByName(typeName) as Class;
				
				this[fieldName] = new typeClass(value);
			} else {
				if (this.hasOwnProperty(fieldName)) {
					if (value == "")
						value = null;
						
					this[fieldName] = value;
				} else {
					trace("ERROR: property " + fieldName + " does not exist on "
						+ getQualifiedClassName(this));
				}
			}
		
			if (fireFieldsChangedEvent)
				this.fieldsChanged();
		}
		
		// populate properties of an instance
		public function setFields(fields:Object):void {
			if (! fields) fields = {};

			for (var field:* in fields) {
				this.setField(field, fields[field], false);
			}
			
			this.fieldsChanged();
		}
		
		// CRUD
		
		static public function create(entityClass:Class, fields:Object=null, cb:Function=null):void {
			var entityFactory:ClassFactory = new ClassFactory(entityClass);
			var self:Entity = entityFactory.newInstance();
			
			self.doRequest("", function (evt:ResultEvent):void {
				self.loadAll();
				if (cb != null)
					cb.apply(self, [ evt ]);
			}, "PUT", fields);
		}
		
		public function deleteEntity(callback:Function=null):void {
			var self:Entity = this;
			this.doRequest("/" + this.id, function (evt:ResultEvent):void {
				if (callback != null)
					callback(self);
			}, "DELETE", this.primaryKey());
		}
				
		// simple accessor for Entity.getEntities()
		[Bindable(event="EntitiesUpdated")] public function get all():ArrayCollection {
			return getEntities(this._class);
		}
		
		// returns entity singleton list
		// does not do any requests
		[Bindable(event="EntitiesUpdated")]
		static public function getEntities(entityClass:Class):ArrayCollection {			
			var className:String = _classIdentifier(entityClass);
			
			if (! Entity._entities[className]) {
				Entity._entities[className] = new ArrayCollection();
			}
			
			return _entities[className];
		}
		
		// reloads a single entity's fields
		public function load(cb:Function=null):void {			
			var self:Entity = this;
						
			doRequest(
				"", 
				function (evt:ResultEvent):void {
					if (cb != null)
						cb.apply(self);
					self.loadComplete(evt);
				},
				"GET",
				self.primaryKey()
			);
		}
		
		// override if PK is not "id"
		public function primaryKey():Object {
			return { "search.id": this.id };
		}
		
		// populate singleton list
		[Bindable(event="EntitiesUpdated")] public function loadAll(search:Object=null, cb:Function=null):void {
			var self:Entity = this;
			var entityClass:Class = this._class;
			this.doRequest("", function (evt:ResultEvent):void {
				Entity.loadEntitiesComplete(entityClass, evt);
				if (cb != null) { cb(); }
			}, "GET", search);
		}
		
		public static function loadAll(entityClass:Class, search:Object=null, cb:Function=null):void {
			doRequest(entityClass, "", function (evt:ResultEvent):void {
				Entity.loadEntitiesComplete(entityClass, evt);
				if (cb != null) { cb(); }
			}, "GET", search);
		}
		
		// save changes to an entity
		public function update(fields:Object, cb:Function=null):void {
			var self:Entity = this;
			
			// add primary key fields for update
			var pk:Object = this.primaryKey();
			for (var pkey:String in pk) {
				if (fields[pkey] || pkey == 'search.id') continue;
				fields[String(pkey)] = pk[pkey];
			}
				
			// update instance immediately
			for (var fkey:String in fields) {
				self[fkey] = fields[fkey];
			}
			
			doRequest("/" + this.id, function (evt:ResultEvent):void {
				self.updateComplete(evt);
				if (cb != null)
					cb();
			}, "POST", fields);
		}
		
		
		//// events
		
		protected function fieldsChanged():void {
			this.dispatchEvent(new Event("FieldsChanged"));
		}
		
		protected function loadComplete(res:ResultEvent):void {
			this.setFields(res.result.opt.data.list);
			this.dispatchEvent(new Event("EntityLoaded"))
		}
				
		protected static function loadEntitiesComplete(entityClass:Class, res:ResultEvent):void {
			var cid:String = _classIdentifier(entityClass);
			debug("loadEntitiesComplete for " + cid);
			
			var entityList:ArrayCollection = _entities[cid];
			if (! entityList)
				entityList = _entities[cid] = new ArrayCollection();
				
			if (! res || ! res.result || ! res.result.opt || ! res.result.opt.data)
				return;
				
			if (res.result.opt.data.list)
				Entity.instantiateList(res.result.opt.data.list, entityClass, entityList);
			else
				entityList.removeAll();
				
			//this.dispatchEvent(new Event("EntitiesUpdated"));
			entityList.dispatchEvent(new Event("EntitiesLoaded"));
		}
		
		protected function updateComplete(evt:ResultEvent):void {
			this.load();
			this.dispatchEvent(new Event("EntityUpdated"));
		}
		
		
		//// utility
		
		// populates listObj with entities of class ctor from data returned from the server in newList
		static public function instantiateList(listObj:Object, ctor:Class, newList:ArrayCollection):void {
			// force into arraycollection, even if it is a single object
			var list:ArrayCollection = listObj as ArrayCollection;
			if (! list && listObj) list = new ArrayCollection([ listObj ]);

			newList.removeAll();
			
			if (! list || ! listObj)
				return;

			for each (var entityFields:Object in list) {
				var entityInstance:Entity = Entity.instantiateRow(entityFields, ctor);
				
				if (! entityInstance) {
					trace("Error instantiating " + ctor);
					continue;
				}
				
				newList.addItem(entityInstance);
			}
		}
		
		// creates a new instance or returns one if one already exists
		// unique singleton id is class / PK
		static protected function getSingleton(rowObj:Object, ctor:Class):Entity {
			var singletons:Object = Entity._singletons[ctor];
			if (! singletons)
				singletons = Entity._singletons[ctor] = new Object();
			
			// for now assume rowObj.id is the PK
			var pk:String = rowObj.id;
			
			var entityInstance:Entity;
			
			if (pk) {
				entityInstance = singletons[pk] as Entity;
				
				// singleton exists
				if (entityInstance) {
					debug("found singleton for " + ctor + " pk: " + pk);
				}			
			}
			
			if (! entityInstance) {
				debug("failed to find singleton for " + ctor + " pk: " + pk);
				// create new singleton
				entityInstance = new ctor as Entity;
				singletons[pk] = entityInstance;
			}
			
			if (! entityInstance) {
				debug("Failed to create singleton instance for " + ctor + " and PK " + pk);
				return null;
			}
			
			entityInstance.setFields(rowObj);
			return entityInstance;
		}
		
		// returns an Entity instance of ctor with the fields in rowObj set
		public static function instantiateRow(rowObj:Object, ctor:Class):Entity {
			if (USE_SINGLETONS_ONLY) {
				// get singleton for this instance
				return getSingleton(rowObj, ctor);
			} else {
				// NON-singleton behavior (for individual entities, still singleton lists for .all)
				var entityInstance:Object = new ctor;
				entityInstance.setFields(rowObj);
				return entityInstance as Entity;
			}
		}
		
		// server error
		protected static function gotFault(evt:FaultEvent, url:String):void {
			trace("Got error for URL " + url + ": " + evt.fault.faultDetail);
			trace("[Stack trace]\n" + evt.fault.getStackTrace());
			//dispatchEvent(evt);
		}
		
		protected function doRequest(url:String="", cb:Function=null, method:String="POST", params:Object=null):void {
			Entity.doRequest(this._class, url, cb, method, params);
		}
		
		// do REST request for rest/className/url
		protected static function doRequest(entityClass:Class, url:String="", cb:Function=null, method:String="POST", params:Object=null):void {
			var className:String = _classIdentifier(entityClass);
			
			var vars:URLVariables = new URLVariables();
			for (var f:String in params) {
				if (! params.hasOwnProperty(f)) continue;
				vars[f] = params[f];
			}
			
			var req:RESTService = new RESTService();
			req.method = method;
			req.url = "rest/" + className + url;
			req.addEventListener(ResultEvent.RESULT, cb);
			req.addEventListener(FaultEvent.FAULT, function (evt:FaultEvent):void {
				gotFault(evt, url);
			});
			
			req.send(vars);
		}
		
		protected function get _class():Class {
			return this.constructor;
		}
		
		protected function get _classIdentifier():String {
			return Entity._classIdentifier(this._class);
		}
		
		// turn a class into a canonical unique identifier to be used internally
		protected static function _classIdentifier(c:Class):String {
			// get type name
			var typeInfo:Object = describeType(c);
			var cname:String = typeInfo.@name;
			
			// cname is now something like "com.doctorbase.entity::Appointment"
			// transform into "notification"
			var matches:Array = cname.match(/\w+$/i);
			if (! matches || ! matches.length) {
				trace("Failed to look up class identifier for " + c);
				return Object(c).toString();
			}
			
			cname = matches[0];
			
			// transform CamelCase into reasonable_names
			cname = cname.replace(/(.)([A-Z])/, "$1_$2");
			cname = cname.toLowerCase();
			
			debug("_classIdentifier(" + c + ") = " + cname);
			return cname;
		}
	}
}
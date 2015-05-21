module.exports = (BasePlugin) ->

	gm = require('gm')
	path = require('path')
	fs = require('fs-extra')
	extendr = require('extendr')
	eachr = require('eachr')
	taskgroup = require('taskgroup')

	class Imagin extends BasePlugin
		name: 'imagin'

		config:
			presets:
				'default':
					q: 85
				'tiny-square':
					w: 50
					h: 50
				'small-square':
					w: 150
					h: 150
				'medium-square':
					w: 300
					h: 300
				'large-square':
					w: 500
					h: 500
				'tiny-wide':
					w: 88
					h: 50
				'small-wide':
					w: 266
					h: 150
				'medium-wide':
					w: 533
					h: 300
				'large-wide':
					w: 888
					h: 500

			targets:
				'default': (img, args) ->
					return img
						.quality(args.q)
						.resize(args.w, args.h)
				'zoomcrop': (img, args) ->
					return img
						.quality(args.q)
						.gravity('Center')
						.resize(args.w, args.h, '^')
						.crop(args.w, args.h)

			imageMagick: false
			extensions: ['jpg', 'JPG', 'jpeg', 'JPEG', 'png', 'PNG']

		thumbnailsToGenerate: null  # Object
		thumbnailsToGenerateLength: 0

		constructor: ->
			super
			@thumbnailsToGenerate = {}

		merge: (obj1, obj2) ->
			return extendr.extend (extendr.extend {}, obj1 ), obj2

		paramsToString: (params) ->
			str = ""
			if params.w?
				str += "w"+params.w
			if params.h?
				str += "h"+params.h
			if params.q?
				str += "q"+params.q
			return str

		extendTemplateData: ({templateData}) ->

			#Prepare
			docpad = @docpad
			me = @
			config = @config

			templateData.getThumbnail = (src, args...) ->
				# return a thumbnail url, generating the image if necessary
				sourceFile = @getFileAtPath(src)
				attributes = undefined
				if sourceFile
					attributes = sourceFile.attributes
				else
					extendedSources = fs.readdirSync(docpad.config.srcPath).filter (file) ->
						fs.statSync(path.join docpad.config.srcPath, file).isDirectory()
					for extendedSource in extendedSources
						sourceFilePath = path.join(docpad.config.srcPath, extendedSource, src)
						if fs.existsSync sourceFilePath
							sourceStats = fs.statSync(sourceFilePath)
							relativeOutDirPath = path.dirname(src)
							if relativeOutDirPath.indexOf('/') == 0
								relativeOutDirPath = relativeOutDirPath.substring(1)
							attributes = {
								fullPath: sourceFilePath
								outDirPath: path.dirname(path.join docpad.config.outPath, src)
								relativeOutDirPath: relativeOutDirPath
								mtime: sourceStats.mtime
								basename: path.basename(sourceFilePath, path.extname(sourceFilePath))
								extension: path.extname(sourceFilePath).substring(1)
							}
							break

				if attributes?
					srcPath = attributes.fullPath
					outDirPath = attributes.outDirPath
					relOutDirPath = attributes.relativeOutDirPath
					mtime = attributes.mtime
					basename = attributes.basename
					ext = attributes.extension

					# first check that file extension is a valid image format
					if ext not in config.extensions
						msg = "Thumbnail source file extension '#{ext}' not recognised"
						docpad.error(msg)
						return ""

					# work out our target chain and params
					targets = []
					params = config.presets['default']
					for a in args
						if typeof a is 'object'
							# this is a params object
							params = me.merge params, a
						else if typeof a is 'function'
							# this is a function that should return a params object
							params = me.merge params, a()
						else
							# treat as a string
							# could be either a target or param preset
							if a of config.targets
								targets.push a
							else if a of config.presets
								params = me.merge params, config.presets[a]
							else
								docpad.log 'warn', "Unknown parameter '#{a}' for image '#{srcPath}'"

					if not targets.length
						t = config.targets["default"]
						if not (typeof t is 'function')
							# this is a reference to a different target
							if not (t of config.targets)
								docpad.error("Target name '#{t}' does not exist")
								return ""
							targets.push t
						else
							targets.push "default"

					sep = path.sep
					suffix = ".thumb_" + targets.join("_") + "_" + me.paramsToString(params)
					thumbfilename = basename + suffix + "." + ext
					dstPath = outDirPath + sep + thumbfilename
					targetUrl = "/"
					if relOutDirPath?.length
						targetUrl += relOutDirPath + "/"
					targetUrl += thumbfilename

					# first check it's not already in our queue
					if not (dstPath of me.thumbnailsToGenerate)
						generate = false
						try
							# check if the thumbnail already exists and is up to date
							stats = fs.statSync(dstPath)
							if stats.mtime < mtime
								generate = true
						catch err
							generate = true

						if generate
							docpad.log 'info', "Imagin is adding #{dstPath} to queue"

							# add to queue
							me.thumbnailsToGenerate[dstPath] = {
								dst: dstPath
								src: srcPath
								targets: targets
								params: params
							}
							me.thumbnailsToGenerateLength++


					return targetUrl

				return ""

			# Chain
			@

		writeAfter: (opts,next) ->

			#Prepare
			docpad = @docpad
			me = @
			config = @config
			failures = 0

			unless @thumbnailsToGenerateLength
				docpad.log 'debug', 'Imagin has nothing to generate'
				return next()

			tasks = new taskgroup.TaskGroup({concurrency: 1}).done (err, results) ->
				if not err?
					docpad.log('info', 'Imagin generation completed successfully')
				else
					docpad.log('error', 'Imagin generation failed ' + err)
				next?()

			eachr @thumbnailsToGenerate, (item, dst) ->
				dstPath = dst
				srcPath = item.src
				targets = item.targets
				params = item.params

				fs.ensureDirSync path.dirname dstPath

				tasks.addTask (complete) ->
					if config.imageMagick
						im = gm.subClass({ imageMagick: true })
						img = im(srcPath)
					else
						img = gm(srcPath)

					# execute the target chain
					for t in targets
						target_handler = config.targets[t]
						img = target_handler(img, params)
					img.noProfile().write(dstPath, (err) ->
						if err
							docpad.log 'warn', "Failed to generate: #{dstPath}"
							docpad.error(err)
							++failures
						else
							docpad.log 'info', "Finished generating "+dstPath

						return complete()
					)

			tasks.run()

			# Chain
			@

		generateAfter: ->

			#Prepare
			docpad = @docpad
			
			docpad.log 'debug', 'imagin: generateAfter'
			@thumbnailsToGenerate = {}
			@thumbnailsToGenerateLength = 0

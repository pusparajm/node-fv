unpack = require './unpack'
{enclosingRectangle, boxDistance} = require './box_math'

# Match text to form schema.
#
# Assumes words are put in reading order by Tesseract.
module.exports.matchText = (formData, formSchema, words, schemaToPage, rawImage) ->
	textFields = formSchema.filter((field) -> field.type is 'text')
	anchors = []
	anchorFields = []
	# Try to find anchor words (unique matches).
	for textField, fieldIndex in textFields
		matches = []
		for word, wordIndex in words when word.text.length > 0
			if not textField.fieldValidator? or textField.fieldValidator(word.text)
				matches.push wordIndex
		if matches.length is 1
			word = words[matches[0]]
			# Safeguard: Disregard matches that are too far off
			fieldPos = schemaToPage textField.box
			continue if Math.abs(word.box.x - fieldPos.x) + Math.abs(word.box.y - fieldPos.y) > 400
			#console.log 'Unique match:', textField, word
			anchor =
				offset:
					x: fieldPos.x - word.box.x
					y: fieldPos.y - word.box.y
				word: word
			anchors.push anchor
			fieldData = unpack formData, textField.path
			fieldData.value = word.text
			fieldData.confidence = word.confidence
			fieldData.box = word.box
			anchorFields.push fieldIndex
			
	# Remove all words we used as anchor.
	for fieldIndex in anchorFields by -1
		textFields.splice fieldIndex, 1
	words = words.filter((word) -> not anchors.some((a) -> a.word is word))

	# Fill in remaining fields
	for field in textFields
		pos = schemaToPage(field.box)
		closestAnchor = findClosestAnchor anchors, pos
		if closestAnchor?
			pos.x -= closestAnchor.offset.x
			pos.y -= closestAnchor.offset.y
		
		startWords = findTwoClosestWords pos, words
		
		# Build some variants of an enclosing box
		boxVariants = [pos]
		for upperLeftWord in startWords
			boxVariants.push
				x: upperLeftWord.box.x
				y: upperLeftWord.box.y
				width: pos.width
				height: pos.height
			boxVariants.push
				x: upperLeftWord.box.x
				y: upperLeftWord.box.y
				width: pos.width * 0.9
				height: pos.height * 0.9
			boxVariants.push
				x: upperLeftWord.box.x
				y: upperLeftWord.box.y
				width: pos.width * 1.1
				height: pos.height * 1.1
				

		# Interpret available words using all variants and remember which would validate
		validatingVariants = []
		for box in boxVariants
			selectedWords = selectWords words, box
			fieldContentCandidate = toText selectedWords
			# Don't try the exact same value twice
			continue if validatingVariants.some (v) -> v.value is fieldContentCandidate
			
			if not field.fieldValidator? or field.fieldValidator(fieldContentCandidate)
				selectedArea = selectedWords[0]?.box
				for word in selectedWords[1..]
					selectedArea = enclosingRectangle selectedArea, word.box
				confidence = getConfidence selectedWords, box, rawImage

				validatingVariants.push
					value: fieldContentCandidate
					confidence: confidence
					box: selectedArea
					words: selectedWords
		
		# Extremely sophisticated conflict solving algorithm
		chosenVariant = validatingVariants[0]

		if validatingVariants.length > 1
			chosenVariant.confidence = Math.max 0, chosenVariant.confidence - 10

		# Set value of target field and remove selected words from candidates
		if chosenVariant?
			fieldData = unpack formData, field.path
			fieldData.value = chosenVariant.value
			fieldData.confidence = Math.round chosenVariant.confidence
			fieldData.box = chosenVariant.box
			for word in chosenVariant.words
				words.splice words.indexOf(word), 1


findClosestAnchor = (anchors, pos) ->
	minDistance = Infinity
	closest = null
	for anchor in anchors
		dist = boxDistance anchor.word.box, pos
		if dist < minDistance
			minDistance = dist
			closest = anchor
	return closest

findTwoClosestWords = (pos, words) ->
	wordDistances = words.map (word) -> {distance: Math.abs(word.box.x - pos.x) + Math.abs(word.box.y - pos.y), word}
	wordDistances = wordDistances.filter (i) -> i.distance < 200
	wordDistances.sort (a, b) -> a.distance - b.distance
	return wordDistances[...2].map (item) -> item.word

selectWords = (words, placement) ->
	selectedWords = []
	right = placement.x + placement.width
	bottom = placement.y + placement.height
	for word in words
		# Select all words that are at least 50% within placement in x direction,
		# touch placement in y direction, and are none of the typical 'character garbage'.
		if (word.box.x + word.box.width / 2) < right and (word.box.x + word.box.width / 2) > placement.x and
				word.box.y < bottom and word.box.y + word.box.height > placement.y and
				word.text not in ['I', '|', '_', '—']
			selectedWords.push word

	# Now decide which words in y direction to take: First line is the one which is nearest to specified y.
	firstLine = undefined
	firstLineDiff = Infinity

	for word in selectedWords
		diff = Math.abs placement.y - word.box.y
		if diff < firstLineDiff
			firstLine = word.box.y
			firstLineDiff = diff
	#console.log 'Chosen as first line:', firstLine
	return (word for word in selectedWords when firstLine - 10 <= word.box.y < firstLine + placement.height - 5)

# Convert series of rectangles to text. Assumes *words* is already ordered in reading direction.
toText = (words) ->
	return '' unless words.length
	lastY = words[0].box.y
	lastWord = ''
	result = ''
	for word in words
		if word.box.y > lastY + 20
			result += '\n'
			# Tesseract tends to split words into sequences of single characters
		else unless lastWord is '' or (lastWord.length is 1 and word.text.length is 1)
			result += ' '
		result += word.text
		lastWord = word.text
		lastY = word.box.y

	return result

getConfidence = (words, placement, rawImage) ->
	if words?.length > 0
		result = 100
		for {confidence} in words
			result = Math.min result, confidence
		return Math.floor result
	else
		# Text allegedly empty; look whether there are any letter-sized blobs in actual image
		cropped = rawImage.crop placement.x - 5, placement.y - 5,
				placement.width + 10, placement.height + 10
		blobs = (comp for comp in cropped.dilate(3,5).connectedComponents(8) when comp.width > 8 and comp.height > 14)
		if blobs.length is 0
			return 99
		else if blobs.length is 1
			return 70
		else if blobs.length is 2
			return 30
		else
			return 0

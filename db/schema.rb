# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_09_01_000005) do
  create_table "availability_rules", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "day_of_week", null: false
    t.time "end_time", null: false
    t.string "label"
    t.string "rule_type", null: false
    t.time "start_time", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id"
    t.index ["user_id", "day_of_week"], name: "index_availability_rules_on_user_id_and_day_of_week"
  end

  create_table "calendar_events", force: :cascade do |t|
    t.boolean "all_day", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "end_at", null: false
    t.integer "meeting_id"
    t.string "source", null: false
    t.datetime "start_at", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["meeting_id"], name: "index_calendar_events_on_meeting_id"
    t.index ["user_id", "start_at"], name: "index_calendar_events_on_user_id_and_start_at"
  end

  create_table "meeting_attendees", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "meeting_id", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["meeting_id", "user_id"], name: "index_meeting_attendees_on_meeting_id_and_user_id", unique: true
    t.index ["user_id"], name: "index_meeting_attendees_on_user_id"
  end

  create_table "meetings", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "created_by_id", null: false
    t.datetime "end_at", null: false
    t.string "guest_name", null: false
    t.string "location_text"
    t.string "location_type", null: false
    t.string "meet_url"
    t.datetime "start_at", null: false
    t.datetime "updated_at", null: false
    t.index ["created_by_id"], name: "index_meetings_on_created_by_id"
    t.index ["start_at"], name: "index_meetings_on_start_at"
  end

  create_table "users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.string "name", null: false
    t.boolean "operator", default: false, null: false
    t.boolean "participant", default: false, null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
  end

  add_foreign_key "availability_rules", "users"
  add_foreign_key "calendar_events", "meetings"
  add_foreign_key "calendar_events", "users"
  add_foreign_key "meeting_attendees", "meetings"
  add_foreign_key "meeting_attendees", "users"
  add_foreign_key "meetings", "users", column: "created_by_id"
end
